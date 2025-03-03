use aiken/crypto.{VerificationKeyHash}
use cardano/assets.{Lovelace}
use aiken/collection/list

//
// Basic key types
//
pub type PaymentKeyHash =
  VerificationKeyHash

pub type StakeKeyHash =
  VerificationKeyHash

//
// Movie Production States
// (You can adapt or rename these as needed)
//
pub type MovieProductionState {
  PreProduction
  Production
  PostProduction
  Distribution
  Completed
  Cancelled
}

//
// Define a "phase" within the movie production schedule.
// Each phase can have its own separate goal and deadline.
// e.g. { phase_name: "PreProduction", phase_goal: 50000, phase_deadline: 1693424091 }
//
pub type MoviePhase {
  phase_name: ByteArray,
  phase_goal: Lovelace,
  phase_deadline: Int,
}

//
// The main datum (stored on-chain) to represent the overall campaign.
// 
// - `movie_title`: The name of the film (e.g., "Cardano: The Documentary").
// - `director`: The film's director or production entity. (Could store a name or handle.)
// - `phases`: A list of phases for each step of production (PreProduction, Production, etc.).
// - `current_phase_index`: Tracks which phase is actively being funded.
// - `creator`: The (payment key hash, stake key hash) of the main campaign owner (producer).
// - `total_budget`: Optional total budget figure for reference (sum of all phases or a higher-level target).
// - `state`: Tracks the overall state of the movie production (e.g., PreProduction, Production, PostProduction, Distribution, Completed, Cancelled).
//
pub type MovieCampaignDatum {
  movie_title: ByteArray,
  director: ByteArray,
  phases: List<MoviePhase>,
  current_phase_index: Int,
  creator: (PaymentKeyHash, StakeKeyHash),
  total_budget: Lovelace,
  state: MovieProductionState,
}

//
// A backer's datum, potentially storing more data than just their key pair.
// For instance, you could include a "tier" to represent reward levels
// ("Executive Producer", "Associate Producer", etc.).
//
pub type MovieBackerDatum {
  backer_pkh: PaymentKeyHash,
  backer_skh: StakeKeyHash,
  phase_index: Int,
}

//
// If you are minting tokens as part of the campaign (e.g., a "state token"
// to identify the campaign or a "support token" to track backer contributions),
// you can define specialized redeemers for those actions.
//
// Example: a `MovieMintRedeemer` with different constructors for
// launching a campaign, contributing, or finalizing rewards.
//
pub type MovieMintRedeemer {
  // Start the entire campaign with the full list of phases.
  LaunchMovieCampaign(MovieCampaignDatum)

  // A backer contributes to the current phase.
  Contribute(MovieBackerDatum)

  // Optionally: a step to close out the current phase
  // and mint any phase-specific reward or transition tokens.
  FinishPhase(MovieBackerDatum)
}

//
// On the spending side, you might define the actions that
// can be taken when spending (or consuming) a UTxO locked by
// the campaign script. For example:
//
pub type MovieCampaignAction {
  // Cancel the campaign outright (by the creator or platform).
  CancelCampaign

  // Move to next phase (if the current phase goal is met).
  // This might combine with releasing partial funds, or you might
  // do that in a separate "Collect" action.
  AdvancePhase

  // Backers can request a refund (if a phase fails or the campaign is cancelled).
  RefundBacker

  // Conclude the campaign completely (e.g., after Distribution or if the final phase is done).
  ConcludeCampaign

  // Optional: a specialized action to distribute final rewards (NFTs, tokens, etc.).
  DistributeRewards
}
