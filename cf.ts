import {
  applyParamsToScript,
  Constr,
  credentialToAddress,
  Data,
  fromText,
  keyHashToCredential,
  Lovelace,
  mintingPolicyToId,
  PolicyId,
  toUnit,
  TxSignBuilder,
  UTxO,
  Validator,
  validatorToAddress,
} from "@lucid-evolution/lucid";

import { koios } from "./providers/koios";
import { adaToLovelace, handleSuccess } from "./utils";
import { WalletConnection } from "./contexts/wallet/WalletContext";
import { MovieBackerDatum, MovieCampaignDatum, MovieCampaignActionRedeemer } from "@/types/crowdfunding";

import { script } from "@/config/script";
import { STATE_TOKEN } from "@/config/crowdfunding";

async function submitTx(tx: TxSignBuilder) {
  const txSigned = await tx.sign.withWallet().complete();
  const txHash = await txSigned.submit();
  return txHash;
}

export async function createCampaign({ lucid, wallet, address, pkh, stakeAddress, skh }, campaign) {
  if (!lucid || !wallet) throw "Wallet not connected";

  const platform = JSON.parse(localStorage.getItem("CrowdfundingPlatform"));
  if (!platform) throw "Crowdfunding platform not configured!";

  const creator = { address, pkh, stakeAddress, skh };
  const utxos = await lucid.wallet().getUtxos();
  if (!utxos.length) throw "Empty Wallet";

  const nonceUTxO = utxos[0];
  const nonceORef = new Constr(0, [String(nonceUTxO.txHash), BigInt(nonceUTxO.outputIndex)]);
  
  const campaignValidator = {
    type: "PlutusV3",
    script: applyParamsToScript(script.Crowdfunding, [platform.pkh, creator.pkh, nonceORef]),
  };
  
  const campaignPolicy = mintingPolicyToId(campaignValidator);
  const campaignAddress = validatorToAddress(network, campaignValidator);
  const StateTokenUnit = toUnit(campaignPolicy, STATE_TOKEN.hex);

  const campaignDatum = {
    name: fromText(campaign.name),
    goal: campaign.goal,
    deadline: campaign.deadline,
    creator: [creator.pkh, creator.skh],
    state: "Running",
  };

  const mintRedeemer = Data.to(campaignDatum, MovieCampaignDatum);

  const now = await koios.getBlockTimeMs();

  const tx = await lucid
    .newTx()
    .collectFrom([nonceUTxO])
    .mintAssets({ [StateTokenUnit]: 1n }, mintRedeemer)
    .attachMetadata(721, {
      [campaignPolicy]: {
        [STATE_TOKEN.assetName]: {
          platform: platform.pkh,
          creator: creator.pkh,
          hash: nonceUTxO.txHash,
          index: nonceUTxO.outputIndex,
        },
      },
    })
    .attach.MintingPolicy(campaignValidator)
    .payToContract(campaignAddress, { kind: "inline", value: mintRedeemer }, { [StateTokenUnit]: 1n })
    .validFrom(now)
    .complete({ localUPLCEval: false });

  const txHash = await submitTx(tx);
  handleSuccess(`Campaign Created! TxHash: ${txHash}`);

  return txHash;
}

export async function supportCampaign({ lucid, wallet, pkh, skh, address }, campaign, supportADA) {
  if (!lucid || !wallet || !address || !campaign) throw "Invalid campaign details";

  const { CampaignInfo } = campaign;
  const backerDatum = Data.to([pkh, skh], MovieBackerDatum);
  const supportLovelace = adaToLovelace(supportADA);

  const tx = await lucid
    .newTx()
    .payToContract(CampaignInfo.address, { kind: "inline", value: backerDatum }, { lovelace: supportLovelace })
    .complete({ localUPLCEval: false });

  const txHash = await submitTx(tx);
  handleSuccess(`Support Transaction Successful! TxHash: ${txHash}`);
  return txHash;
}

export async function advancePhase({ lucid, wallet }, campaign) {
  if (!lucid || !wallet || !campaign) throw "Invalid request";

  const { CampaignInfo } = campaign;
  const stateTokenUTxO = await lucid.utxosAtWithUnit(CampaignInfo.address, campaign.StateToken.unit);
  const advanceRedeemer = Data.to(MovieCampaignActionRedeemer.AdvancePhase);

  const tx = await lucid
    .newTx()
    .collectFrom([stateTokenUTxO], advanceRedeemer)
    .attachSpendingValidator(CampaignInfo.validator)
    .complete({ localUPLCEval: false });

  const txHash = await submitTx(tx);
  handleSuccess(`Phase Advanced! TxHash: ${txHash}`);
  return txHash;
}

export async function refundBackers({ lucid, wallet }, campaign) {
  if (!lucid || !wallet || !campaign) throw "Invalid request";

  const { CampaignInfo, StateToken } = campaign;
  if (!CampaignInfo.data.support.ada) throw "Nothing to refund";

  const tx = await lucid
    .newTx()
    .readFrom([StateToken.utxo])
    .collectFrom(
      CampaignInfo.data.backers.map(({ utxo }) => utxo),
      Data.to(MovieCampaignActionRedeemer.RefundBacker)
    )
    .attachSpendingValidator(CampaignInfo.validator);

  for (const { address, support } of CampaignInfo.data.backers) {
    tx.payToAddress(address, { lovelace: support.lovelace });
  }

  const finalTx = await tx.complete({ localUPLCEval: false });
  const txHash = await submitTx(finalTx);
  handleSuccess(`Refund Processed! TxHash: ${txHash}`);
  return txHash;
}

export async function concludeCampaign({ lucid, wallet }, campaign) {
  if (!lucid || !wallet || !campaign) throw "Invalid request";

  const { CampaignInfo } = campaign;
  const stateTokenUTxO = await lucid.utxosAtWithUnit(CampaignInfo.address, campaign.StateToken.unit);
  const concludeRedeemer = Data.to(MovieCampaignActionRedeemer.ConcludeCampaign);

  const tx = await lucid
    .newTx()
    .collectFrom([stateTokenUTxO], concludeRedeemer)
    .attachSpendingValidator(CampaignInfo.validator)
    .complete({ localUPLCEval: false });

  const txHash = await submitTx(tx);
  handleSuccess(`Campaign Concluded! TxHash: ${txHash}`);
  return txHash;
}
