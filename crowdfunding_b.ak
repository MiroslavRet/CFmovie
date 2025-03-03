use aiken/crypto.{VerificationKeyHash}
use cardano/assets.{PolicyId}
use cardano/transaction.{OutputReference, Transaction}
use crowdfunding
use crowdfunding/types.{MovieCampaignAction, MovieMintRedeemer, MovieBackerDatum, MovieCampaignDatum}

validator campaign(
  platform: VerificationKeyHash,
  creator: VerificationKeyHash,
  nonce: OutputReference,
) {
  mint(
    redeemer: Option<Data>,
    policy_id self_script: PolicyId,
    tx: Transaction,
  ) {
    crowdfunding.validate_mint_movie_campaign(
      creator,
      nonce,
      redeemer,
      self_script,
      tx,
      platform,
    )
  }

  spend(
    datum: Option<Data>,
    redeemer: MovieCampaignAction,
    o_ref: OutputReference,
    tx: Transaction,
  ) {
    crowdfunding.validate_spend_movie_campaign(
      platform,
      creator,
      nonce,
      datum,
      redeemer,
      o_ref,
      tx,
    )
  }

  else(_) {
    fail
  }
}