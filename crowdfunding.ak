use aiken/collection/dict
use aiken/collection/list
use aiken/crypto.{VerificationKeyHash}
use cardano/address.{Address, Script, VerificationKey}
use cardano/assets.{Lovelace, PolicyId}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction,
}
use config
use crowdfunding/types.{
  MovieCampaignDatum,
  MovieBackerDatum,
  MovieCampaignAction, 
  MovieMintRedeemer,
  LaunchMovieCampaign,
  Contribute,
  FinishPhase,
  CancelCampaign,
  AdvancePhase,
  RefundBacker,
  ConcludeCampaign,
  DistributeRewards,
  PreProduction,
  Production,
  PostProduction,
  Distribution,
  Completed,
  Cancelled,

  
}
use crowdfunding/utils.{address_from_tuple}
use test_kit/time/unwrap



pub fn validate_mint_movie_campaign(
  campaign_creator: VerificationKeyHash,
  nonce: OutputReference,
  redeemer: Option<Data>,
  self_script: PolicyId,
  tx: Transaction,
  platform: VerificationKeyHash,
) -> Bool {
  when redeemer is {
    Some(current_redeemer) ->
      if current_redeemer is LaunchMovieCampaign(campaign_datum): MovieMintRedeemer {
        tx |> validate_launch_movie_campaign(self_script, campaign_datum, nonce, campaign_creator)
      } else if current_redeemer is Contribute(backer_datum): MovieMintRedeemer {
        tx |> validate_contribution(self_script, backer_datum)
      } else if current_redeemer is FinishPhase(backer_datum): MovieMintRedeemer {
        tx |> validate_finish_phase(self_script, backer_datum)
      } else {
        False
      }

    None -> False
  }
}

pub fn validate_spend_movie_campaign(
  platform: VerificationKeyHash,
  campaign_creator: VerificationKeyHash,
  nonce: OutputReference,
  datum: Option<Data>,
  action: MovieCampaignAction,
  o_ref: OutputReference,
  tx: Transaction,
) -> Bool {

  expect Some(Input { output: Output { address, .. }, .. }) =
    tx.inputs |> transaction.find_input(o_ref)
  expect Script(self_script) = address.payment_credential
  // This snippet finds the input being spent that references the script output

  when (datum, action) is {
    // Example: Cancel the entire campaign
    (Some(current_datum), CancelCampaign) -> {
      if current_datum is campaign_datum: MovieCampaignDatum {
        tx |> validate_cancel_movie_campaign(self_script, campaign_datum, platform)
      } else {
        fail @"Invalid datum type for CancelCampaign!"
      }
    }

    // Refund the backer
    (Some(current_datum), RefundBacker) -> {
      if current_datum is backer_datum: MovieBackerDatum {
        tx |> validate_backer_refund(self_script, backer_datum)
      } else {
        fail @"Invalid datum type for RefundBacker!"
      }
    }

    // Advance from one phase to the next
    (Some(current_datum), AdvancePhase) -> {
      if current_datum is campaign_datum: MovieCampaignDatum {
        tx |> validate_advance_phase(self_script, campaign_datum, platform)
      } else {
        fail @"Invalid datum type for AdvancePhase!"
      }
    }

    // Collect partial or final funds to the creator
    (Some(current_datum), DistributeRewards) -> {
      if current_datum is campaign_datum: MovieCampaignDatum {
        tx |> validate_collect_phase_funds(self_script, campaign_datum)
      } else {
        fail @"Invalid datum type for CollectFunds!"
      }
    }

    // Conclude the entire campaign (e.g., after final phase)
    (Some(current_datum), ConcludeCampaign) -> {
      if current_datum is campaign_datum: MovieCampaignDatum {
        tx |> validate_conclude_campaign(self_script, campaign_datum, platform)
      } else {
        fail @"Invalid datum type for ConcludeCampaign!"
      }
    }

    // Otherwise, if no known action, or no datum
    _ -> {
      expect !is_running_campaign(tx.reference_inputs, self_script)
      tx |> must_be_signed_by(platform)
    }
  }
}

fn validate_launch_movie_campaign(
  tx: Transaction,
  self_script: PolicyId,
  campaign_datum: MovieCampaignDatum,
  nonce: OutputReference,
  creator: VerificationKeyHash,
) -> Bool {

  expect MovieCampaignDatum { phases, current_phase_index, creator: (pkh, _), .. } = campaign_datum
  expect creator == pkh
  expect current_phase_index == 0
  expect !list.is_empty(phases)

  // Ensure the transaction start time is before the first phase deadline
  expect Some(first_phase) = list.at(phases, 0)
  let first_phase_deadline = first_phase.phase_deadline
  expect unwrap.finite_start_of(tx.validity_range) < first_phase_deadline

  and {
    must_consume_creator_nonce(tx, creator, nonce)?,
    must_mint_state_token(tx, self_script)?,
    must_output_state_token_for_movie_campaign(tx, self_script, campaign_datum)?,
  }
}


fn validate_cancel_movie_campaign(
  tx: Transaction,
  self_script: PolicyId,
  campaign_datum: MovieCampaignDatum,
  platform: VerificationKeyHash,
) -> Bool {
  let is_signed_by_platform = must_be_signed_by(tx, platform)

  // E.g., platform can only cancel after some global “last phase deadline” or certain conditions
  // while creator can cancel at any time
  and {
    if is_signed_by_platform? {
      // Extract the last phase safely from the list
      expect Some(last_phase) = list.last(campaign_datum.phases)
      must_be_after_deadline(tx, last_phase.phase_deadline)?
    } else {
      must_be_signed_by(tx, campaign_datum.creator.1st)?
    },

    is_running_campaign(tx.inputs, self_script)?,

    must_output_state_token_for_movie_campaign(
      tx,
      self_script,
      MovieCampaignDatum { ..campaign_datum, state: Cancelled },
    )?,
  }
}



fn validate_backer_refund(
  tx: Transaction,
  self_script: PolicyId,
  backer_datum: MovieBackerDatum,
) -> Bool {
  expect !is_running_campaign(tx.reference_inputs, self_script)
  // Ensure the campaign or the relevant phase is cancelled/failed, etc.
  // Then give back the backer's lovelace from the script address to their address
  must_refund_backer(tx, self_script, backer_datum)?
}

// ## Helper Functions

fn is_running_campaign(tx_inputs: List<Input>, self_script: PolicyId) -> Bool {
  // must consume/refer state token UTxO
  expect Some(Input { output: Output { datum, .. }, .. }) = {
    let input <- list.find(tx_inputs)
    assets.quantity_of(input.output.value, self_script, config.state_token) == 1
  }

  // must be campaign inline datum
   expect InlineDatum(campaign_datum) = datum
  expect MovieCampaignDatum { state, .. } = campaign_datum

  // Check if the state is one of the active production states
  state == PreProduction || state == Production || state == PostProduction || state == Distribution
}

fn must_be_signed_by(tx: Transaction, signer: VerificationKeyHash) -> Bool {
  // just expect 1 signer
  ([signer] == tx.extra_signatories)?
}



fn must_be_after_deadline(tx: Transaction, deadline: Int) -> Bool {
  // tx validFrom is after or at deadline
  (unwrap.finite_start_of(tx.validity_range) >= deadline)?
}

fn validate_advance_phase(
  tx: Transaction,
  self_script: PolicyId,
  campaign_datum: MovieCampaignDatum,
  platform: VerificationKeyHash,
) -> Bool {
  let is_signed_by_platform = must_be_signed_by(tx, platform)
  let current_index = campaign_datum.current_phase_index
  let maybe_phase = list.at(campaign_datum.phases, current_index)
  let next_index = current_index + 1
  expect Some(current_phase) = maybe_phase

  let updated_datum = if next_index < list.length(campaign_datum.phases) {
    MovieCampaignDatum { ..campaign_datum, current_phase_index: next_index }
  } else {
    // No more phases => set campaign to Completed
    MovieCampaignDatum { ..campaign_datum, state: Completed }
  }

  and {
    // 1) If platform signed, check deadline; else check campaign creator signature.
    if is_signed_by_platform? {
      must_be_before_or_at_deadline(tx, current_phase.phase_deadline)?
    } else {
      must_be_signed_by(tx, campaign_datum.creator.1st)?
    },

    // 2) Must have reached phase goal
    must_reach_phase_goal(tx, self_script, current_phase.phase_goal)?,

    // 3) Must be a running campaign
    is_running_campaign(tx.inputs, self_script)?,

    // 4) Output the updated campaign state token
    must_output_state_token_for_movie_campaign(tx, self_script, updated_datum)?,
  }
}


fn validate_collect_phase_funds(
  tx: Transaction,
  self_script: PolicyId,
  campaign_datum: MovieCampaignDatum
) -> Bool {
  // Ensure the campaign is active (e.g., not ended or canceled)
  expect is_running_campaign(tx.reference_inputs, self_script)

  // Get the current phase's goal
  let current_phase = list.at(campaign_datum.phases, campaign_datum.current_phase_index)
  expect Some(phase) = current_phase
  let phase_goal = phase.phase_goal

  // Verify the phase goal is met and distribute funds
  must_reach_phase_goal(tx, self_script, phase_goal) &&
  must_reach_phase_goal_and_send_to_creator(tx, self_script, phase_goal, campaign_datum.creator)
}

// Example: Conclude entire campaign after the final phase
fn validate_conclude_campaign(
  tx: Transaction,
  self_script: PolicyId,
  campaign_datum: MovieCampaignDatum,
  platform: VerificationKeyHash,
) -> Bool {
  let last_phase = when list.last(campaign_datum.phases) is {
    Some(phase) -> phase
    None -> fail @"Campaign has no phases"
  }

  and {
    // 1) Check if the platform signed. If not, the creator must sign.
    if !must_be_signed_by(tx, platform)? {
      must_be_signed_by(tx, campaign_datum.creator.1st)?
    } else {
      True
    },

    // 2) Check we are after the last phase’s deadline
    must_be_after_deadline(tx, last_phase.phase_deadline)?,

    // 3) Finally, output an updated datum with state=Completed
    must_output_state_token_for_movie_campaign(
      tx,
      self_script,
      MovieCampaignDatum { ..campaign_datum, state: Completed },
    )?,
  }
}





fn must_reach_phase_goal(
  tx: Transaction,
  self_script: PolicyId,
  phase_goal: Lovelace
) -> Bool {
  let script_address = Address(Script(self_script), None)

  // Find the state token UTxO in reference inputs to get the current phase index
  expect Some(state_input) = list.find(
    tx.reference_inputs,
    fn(input) {
      input.output.address == script_address &&
      assets.quantity_of(input.output.value, self_script, config.state_token) == 1
    }
  )

  // Extract MovieCampaignDatum from the state token UTxO
  expect InlineDatum(campaign_datum) = state_input.output.datum
  expect MovieCampaignDatum { current_phase_index, .. } = campaign_datum

  // Sum Lovelace from inputs where phase_index matches current_phase_index
  let sum_support = fn(sum, input: Input) {
    if input.output.address == script_address {
      when input.output.datum is {
        InlineDatum(datum) -> {
          if datum is MovieBackerDatum {
            if datum.phase_index == current_phase_index {
              sum + assets.lovelace_of(input.output.value)
            } else {
              sum
            }
          } else {
            sum
          }
        }
        _ -> sum
      }
    } else {
      sum
    }
  }

  let total = list.reduce(tx.inputs, 0, sum_support)
  total >= phase_goal
}

fn must_reach_phase_goal_and_send_to_creator(
  tx: Transaction,
  self_script: PolicyId,
  phase_goal: Lovelace,
  (creator_pkh, creator_skh)
) -> Bool {
  let self_address = Address(Script(self_script), None)

  // Find state token UTxO (unchanged)
  expect Some(state_input) = list.find(
    tx.reference_inputs,
    fn(input) {
      input.output.address == self_address &&
      assets.quantity_of(input.output.value, self_script, config.state_token) == 1
    }
  )

  // Extract current_phase_index (unchanged)
  expect InlineDatum(campaign_datum) = state_input.output.datum
  expect MovieCampaignDatum { current_phase_index, .. } = campaign_datum

  // Use the corrected sum_support
  let sum_support = fn(sum, Input { output: Output { address, datum, value, .. }, .. }) {
    if address == self_address {
      when datum is {
        InlineDatum(datum) ->
          if datum is MovieBackerDatum {
            if datum.phase_index == current_phase_index {
              sum + assets.lovelace_of(value)
            } else {
              sum
            }
          } else {
            sum
          }
        _ -> sum
      }
    } else {
      sum
    }
  }
  let supports = list.reduce(tx.inputs, 0, sum_support)

  // Rest of the function (unchanged)
  let creator_address = utils.address_from_tuple((creator_pkh, creator_skh))
  let sum_creator = fn(sum, output: Output) {
    if output.address == creator_address {
      sum + assets.lovelace_of(output.value)
    } else {
      sum
    }
  }
  let total_to_creator = list.reduce(tx.outputs, 0, sum_creator)

  (supports >= phase_goal) && (total_to_creator >= supports)
}

fn must_output_state_token_for_movie_campaign(
  tx: Transaction,
  self_script: PolicyId,
  campaign_datum: MovieCampaignDatum,
) -> Bool {
  let datum_data: Data = campaign_datum
  let movie_script_address = Address(Script(self_script), None)

  let Output { address, datum, value, .. } <- list.any(tx.outputs)

  when datum is {
    InlineDatum(output_datum) ->
      and {
        address == movie_script_address,
        output_datum == datum_data,
        assets.quantity_of(value, self_script, config.state_token) == 1,
      }
    _ -> False
  }
}

fn must_send_support_token(
  tx: Transaction,
  self_script: PolicyId,
  backer_datum: MovieBackerDatum,
) -> Bool {
  let with_backer_datum_data: Data = backer_datum
  let self_address = address.from_script(self_script)
  let Output { address, datum, value, .. } <- list.any(tx.outputs)

  when datum is {
    InlineDatum(output_datum) -> and {
        address == self_address,
        output_datum == with_backer_datum_data,
        assets.quantity_of(value, self_script, config.support_token) == 1,
      }

    _ -> False
  }
}

fn must_mint_state_token(tx: Transaction, self_script: PolicyId) -> Bool {
  let minted_tokens = tx.mint |> assets.tokens(self_script) |> dict.to_pairs()

  // restrict minting to 1 quantity and 1 asset name with self Policy ID
  ([Pair(config.state_token, 1)] == minted_tokens)?
}

fn must_consume_creator_nonce(
  tx: Transaction,
  creator: VerificationKeyHash,
  nonce: OutputReference,
) -> Bool {
  let Input(
    output_reference,
    Output { address: Address { payment_credential, .. }, .. },
  ) <- list.any(tx.inputs)

  // the nonce utxo must come from the campaign creator
  and {
    output_reference == nonce,
    VerificationKey(creator) == payment_credential,
  }
}

fn validate_contribution(
  tx: Transaction,
  self_script: PolicyId,
  backer_datum: MovieBackerDatum,
) -> Bool {
  and {
    must_mint_support_token_1(tx, self_script)?,
    must_send_support_token(tx, self_script, backer_datum)?,
  }
}

fn must_mint_support_token_1(tx: Transaction, self_script: PolicyId) -> Bool {
  let minted_qty =
    assets.quantity_of(tx.mint, self_script, config.support_token)
  minted_qty == 1
}

fn validate_finish_phase(
  tx: Transaction,
  self_script: PolicyId,
  backer_datum: MovieBackerDatum,
) -> Bool {
  // Example: you might require that the current phase’s goal is reached
  // and we burn the support token(s) while minting reward tokens
  must_mint_reward_burn_support(tx, self_script, backer_datum)?
}





// Refund logic for backer (if a phase fails or campaign is cancelled)
fn must_refund_backer(
  tx: Transaction,
  self_script: PolicyId,
  backer_datum: MovieBackerDatum,
) -> Bool {
  // Similar to your original must_refund logic, but referencing MovieBackerDatum
  let backer_datum_data: Data = backer_datum
  let script_address = Address(Script(self_script), None)

  // 1. Sum how much the backer contributed from script
  let input_sum = fn(sum, Input { output, .. }) {
    if output.address == script_address {
      when output.datum is {
        InlineDatum(inline_datum) -> 
          if inline_datum == backer_datum_data {
            assets.lovelace_of(output.value) + sum
          } else {
            sum
          }
        _ -> sum
      }
    } else {
      sum
    }
  }
  let input_lovelace = list.reduce(tx.inputs, 0, input_sum)

  // 2. Check how much is returned to the backer's address
  let backer_address = utils.address_from_tuple((backer_datum.backer_pkh, backer_datum.backer_skh))
  let output_sum = fn(sum, Output { address, value, .. }) {
    if address == backer_address {
      assets.lovelace_of(value) + sum
    } else {
      sum
    }
  }
  let returned_lovelace = list.reduce(tx.outputs, 0, output_sum)

  (returned_lovelace >= input_lovelace)?
}

// Burn the support tokens and mint any reward tokens for finishing a phase
fn must_mint_reward_burn_support(
  tx: Transaction,
  self_script: PolicyId,
  backer_datum: MovieBackerDatum,
) -> Bool {
  let backer_datum_data: Data = backer_datum
  let script_address = Address(Script(self_script), None)

  // 1. Count how many support tokens are in the script inputs for this backer
  let input_support_tokens = list.reduce(
    tx.inputs,
    0,
    fn(sum, Input { output, .. }) {
      if output.address == script_address {
        when output.datum is {
          InlineDatum(inline_datum) -> 
            if inline_datum == backer_datum_data {
              sum + assets.quantity_of(output.value, self_script, config.support_token)
            } else {
              sum
            }
          _ -> sum
        }
      } else {
        sum
      }
    },
  )

  // 2. Check minted/burned tokens in this transaction
  let minted_burned_tokens = tx.mint |> assets.tokens(self_script) |> dict.to_pairs()
  let required_pattern = [
    Pair(config.reward_token, input_support_tokens),   // Mint reward
    Pair(config.support_token, -input_support_tokens), // Burn support
  ]
  let mint_burn_ok = minted_burned_tokens == required_pattern

  // 3. Ensure the new reward tokens end up at the backer’s address
  let backer_address = utils.address_from_tuple((backer_datum.backer_pkh, backer_datum.backer_skh))
  let sum_rewards = fn(sum, Output { address, value, .. }) {
    if address == backer_address {
      assets.quantity_of(value, self_script, config.reward_token) + sum
    } else {
      sum
    }
  }
  let reward_tokens_out = list.reduce(tx.outputs, 0, sum_rewards)
  let reward_ok = reward_tokens_out >= input_support_tokens

  (mint_burn_ok && reward_ok)?
}



fn must_be_before_or_at_deadline(tx: Transaction, deadline: Int) -> Bool {
  (unwrap.finite_start_of(tx.validity_range) <= deadline)?
}



// Function to get the deadline of a phase by its name
//
fn get_phase_deadline_by_name(campaign: MovieCampaignDatum, phase_name: ByteArray) -> Option<Int> {
  when list.find(campaign.phases, fn(phase) { phase.phase_name == phase_name }) is {
    Some(phase) -> Some(phase.phase_deadline)
    None -> None
  }
}

//
// Function to get the current phase deadline
//
fn get_current_phase_deadline(campaign: MovieCampaignDatum) -> Option<Int> {
  when list.at(campaign.phases, campaign.current_phase_index) is {
    Some(phase) -> Some(phase.phase_deadline)
    None -> None
  }
}