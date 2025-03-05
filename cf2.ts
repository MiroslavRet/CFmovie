/***************************************************
 * FINAL MOVIE CROWDFUNDING OFFCHAIN SCRIPT
 ***************************************************/
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
    toText,
    toUnit,
    TxSignBuilder,
    UTxO,
    Validator,
    validatorToAddress,
  } from "@lucid-evolution/lucid";
    
    import { koios } from "@/components/providers/koios"; 
    import { adaToLovelace, handleSuccess } from "@/components/utils"; 
    import { WalletConnection } from "@/components/contexts/wallet/WalletContext";
    import { BackerUTxO, CampaignUTxO, MovieCampaignDatum, MovieProductionState  } from "./contexts/campaign/MovieCampaignContext";
    import { network } from "@/config/lucid";
    import { script } from "@/config/script";
    import { STATE_TOKEN } from "@/config/crowdfunding";
    
    /*******************************************
     * 0) Submit Transaction helper
     *******************************************/
    async function submitTx(txComplete: TxComplete): Promise<string> {
      const signedTx = await txComplete.sign().complete();
      const txHash = await signedTx.submit();
      return txHash;
    }
    
    /*******************************************
     * 1) Building datums + states as Constr
     *******************************************/
    function stateToConstr(stateStr: string): Constr<any> {
      switch (stateStr) {
        case "PreProduction":  return new Constr(0, []);
        case "Production":     return new Constr(1, []);
        case "PostProduction": return new Constr(2, []);
        case "Distribution":   return new Constr(3, []);
        case "Completed":      return new Constr(4, []);
        case "Cancelled":      return new Constr(5, []);
        default:
          throw new Error("Unknown MovieProductionState: " + stateStr);
      }
    }
    
    function buildMoviePhase({
      phase_name,
      phase_goal,
      phase_deadline,
    }: {
      phase_name: string;
      phase_goal: bigint;
      phase_deadline: bigint;
    }): Constr<any> {
      return new Constr(0, [
        fromText(phase_name),
        phase_goal,
        phase_deadline,
      ]);
    }
    
    function buildPhasesList(phasesArr: {
      phase_name: string;
      phase_goal: bigint;
      phase_deadline: bigint;
    }[]): any {
      const phaseConstrs = phasesArr.map(buildMoviePhase);
      return Data.list(phaseConstrs);
    }
    
    function buildCreatorTuple(pkh: string, skh: string): Constr<any> {
      return new Constr(0, [fromText(pkh), fromText(skh)]);
    }
    
    // MovieCampaignDatum
    export interface CampaignParams {
      movie_title: string;
      director: string;
      phases: {
        phase_name: string;
        phase_goal: bigint;
        phase_deadline: bigint;
      }[];
      current_phase_index: number;
      creator_pkh: string;
      creator_skh: string;
      total_budget: bigint;
      state: MovieProductionState; // e.g. "PreProduction"
    }
    
    function buildMovieCampaignDatum(params: CampaignParams): Constr<any> {
        return new Constr(0, [
          fromText(params.movie_title),
          fromText(params.director),
          buildPhasesList(params.phases),
          BigInt(params.current_phase_index),
          buildCreatorTuple(params.creator_pkh, params.creator_skh),
          params.total_budget,
          stateToConstr(params.state),
        ]);
      }

    const moovieCampaignDatumconstr = new Constr(0, [
      fromText(movie_title),
      fromText(director),
      buildPhasesList(phases),
      BigInt(current_phase_index),
      buildCreatorTuple(creator_pkh, creator_skh),
      total_budget,
      stateToConstr(state),
    ]);
    
    const bsckerCFconstr = new Constr(0, [
      fromText(backer_pkh),
      fromText(backer_skh),
      BigInt(phase_index),
    ]);
  
    const creator = new Constr(0, [fromText(pkh), fromText(skh)]);
  
    // MovieBackerDatum
    export interface BackerParams {
      backer_pkh: string;
      backer_skh: string;
      phase_index: number;
    }
    
    function buildMovieBackerDatum(params: BackerParams): Constr<any> {
      return new Constr(0, [
        fromText(params.backer_pkh),
        fromText(params.backer_skh),
        BigInt(params.phase_index),
      ]);
    }
    
  
    
    /**
     * Loads a campaign by policy ID, reading Koios token metadata
     * and building the script address. Then fetches the state token UTxO.
     * 
     * 
     */
    export async function queryCampaign(
      { lucid, wallet }: WalletConnection,
      campaignPolicyId: PolicyId,
    ): Promise<CampaignUTxO> {
      if (!lucid) throw "Uninitialized Lucid";
      if (!wallet) throw "Disconnected Wallet";
    
      //#region Campaign Info
      const campaign = await koios.getTokenMetadata(campaignPolicyId);
      const { platform, creator, hash, index } =
        campaign[campaignPolicyId].STATE_TOKEN;
      const StateTokenUnit = toUnit(campaignPolicyId, STATE_TOKEN.hex); // `${PolicyID}${AssetName}`
    
      const nonceTxHash = String(hash);
      const nonceTxIdx = BigInt(index);
      const nonceORef = new Constr(0, [nonceTxHash, nonceTxIdx]);
    
      const campaignValidator: Validator = {
        type: "PlutusV3",
        script: applyParamsToScript(script.Crowdfunding, [
          platform,
          creator,
          nonceORef,
        ]),
      };
      const campaignAddress = validatorToAddress(network, campaignValidator);
      //#endregion
    
      const [StateTokenUTxO] = await lucid.utxosAtWithUnit(
        campaignAddress,
        StateTokenUnit,
      );
    
      if (!StateTokenUTxO.datum) throw "No Datum";
    
      const campaignDatum = Data.from<CampaignParams>(StateTokenUTxO.datum);
    
      //#region Creator Info
      const creatorPkh1 = campaignDatum.creator_pkh;
  const creatorSkh1 = campaignDatum.creator_skh;
      const creatorPk = keyHashToCredential(creatorPkh1);
      const creatorSk = keyHashToCredential(creatorSkh1);
      const creatorAddress = credentialToAddress(network, creatorPk, creatorSk);
      //#endregion
    
      if (!lucid.wallet()) {
        const api = await wallet.enable();
    
        lucid.selectWallet.fromAPI(api);
      }
    
      //#region Backers Info
      const utxos = await lucid.utxosAt(campaignAddress);
      const backers: BackerUTxO[] = [];
      const noDatumUTXOs: UTxO[] = [];
    
      for (const utxo of utxos) {
        if (!utxo.datum) {
          noDatumUTXOs.push(utxo);
        } else {
          try {
            const [pkh, skh, phaseIndexBigInt] = Data.from<[string, string, bigint]>(utxo.datum);
            const backerPk = keyHashToCredential(pkh);
            const backerSk = skh ? keyHashToCredential(skh) : undefined;
            const phase_index = Number(phaseIndexBigInt);
            const backerAddress = credentialToAddress(network, backerPk, backerSk);
    
            const supportLovelace = utxo.assets.lovelace;
            const supportADA = parseFloat(
              `${supportLovelace / 1_000000n}.${supportLovelace % 1_000000n}`,
            );
    
            backers.push({
              utxo,
              pkh,
              skh,
              pk: backerPk,
              sk: backerSk,
              address: backerAddress,
              support: { lovelace: supportLovelace, ada: supportADA },
              phase_index,
            });
          } catch {
            continue;
          }
        }
      }
      //#endregion
    
      const supportLovelace = backers.reduce(
        (sum, { support }) => sum + support.lovelace,
        0n,
      );
      const supportADA = parseFloat(
        `${supportLovelace / 1_000000n}.${supportLovelace % 1_000000n}`,
      );
    
      return {
        MovieInfo: {
          id: campaignPolicyId,
          platform: { pkh: platform },
          nonce: { txHash: hash, outputIndex: index },
          validator: campaignValidator,
          address: campaignAddress,
          datum: campaignDatum, // Keep the raw on-chain datum as is
          data: {
            movieTitle: toText(campaignDatum.movie_title),
            director: toText(campaignDatum.director),
            phases: campaignDatum.phases.map(phase => ({
              phase_name: phase.phase_name,
              phase_goal: phase.phase_goal,
              phase_deadline: Number(phase.phase_deadline), // Convert bigint → number
            })),
            currentPhaseIndex: campaignDatum.current_phase_index, // Matches CampaignUTxO type
            state: campaignDatum.state, // Should be correctly typed now
            backers,
            noDatum: noDatumUTXOs,
            support: { lovelace: supportLovelace, ada: supportADA },
          },
        },
        StateToken: {
          unit: StateTokenUnit,
          utxo: StateTokenUTxO,
        },
      };
    }
    
    /*******************************************
     * 3) Mint Validator Transactions
     *******************************************/
    export async function launchMovieCampaign(
      { lucid, wallet, pkh }: WalletConnection,
      platformPkh: string,
      nonceUTxO: UTxO,
      campaignParams: CampaignParams
    ) {
      if (!lucid || !wallet) throw new Error("Lucid or Wallet not initialized");
      const datumConstr = buildMovieCampaignDatum(campaignParams);
    
      // Redeemer: LaunchMovieCampaign => constructor(0)
      const launchRedeemer = new Constr(0, [datumConstr]);
      const launchRedeemerData = Data.to(launchRedeemer);
    
      // Mint policy
      const mintValidator: Validator = {
        type: "PlutusV3",
        script: applyParamsToScript(script.Crowdfunding, [
          pkh,
          nonceUTxO.txHash,
          platformPkh,
        ]),
      };
      const policyId = mintingPolicyToId(mintValidator);
      const stateTokenUnit = toUnit(policyId, "state_token");
    
      // Spend validator
      const spendValidator: Validator = {
        type: "PlutusV3",
        script: applyParamsToScript(script.Crowdfunding, [
          platformPkh,
          pkh,
          nonceUTxO.txHash,
        ]),
      };
      const scriptAddress = validatorToAddress(network, spendValidator);
    
      // Build TX
      const tx = await lucid
        .newTx()
        .collectFrom([nonceUTxO])
        .mintAssets({ [stateTokenUnit]: 1n }, launchRedeemerData)
        .attach.MintingPolicy(mintValidator)
        .pay.ToContract(
          scriptAddress,
          { kind: "inline", value: Data.to(datumConstr) },
          { [stateTokenUnit]: 1n }
        )
        .complete();
    
      const txHash = await submitTx(tx);
      handleSuccess(`Launched movie campaign: ${txHash}`);
      return txHash;
    }
    
    export async function contributeToCampaign(
      { lucid, wallet }: WalletConnection,
      policyId: string,
      scriptAddress: string,
      backerParams: BackerParams,
      contributionAda: string
    ) {
      if (!lucid || !wallet) throw new Error("Lucid or Wallet not initialized");
      const backerDatum = buildMovieBackerDatum(backerParams);
      const contRedeemer = new Constr(1, [backerDatum]);
      const contRedeemerData = Data.to(contRedeemer);
    
      // Mint 1 support token
      const supportTokenUnit = toUnit(policyId, "support_token");
      const mintedAssets = { [supportTokenUnit]: 1n };
      const lovelace = adaToLovelace(contributionAda);
    
      const tx = await lucid
        .newTx()
        .mintAssets(mintedAssets, contRedeemerData)
        .attach.MintingPolicy({ type: "PlutusV3", script: script.Crowdfunding })
        .pay.ToContract(
          scriptAddress,
          { kind: "inline", value: Data.to(backerDatum) },
          { lovelace, [supportTokenUnit]: 1n }
        )
        .complete();
    
      const txHash = await submitTx(tx);
      handleSuccess(`Contributed to campaign: ${txHash}`);
      return txHash;
    }
    
    export async function finishPhase(
      { lucid, wallet }: WalletConnection,
      policyId: string,
      scriptAddress: string,
      backerParams: BackerParams
    ) {
      if (!lucid || !wallet) throw new Error("Lucid or Wallet not initialized");
      const backerDatum = buildMovieBackerDatum(backerParams);
    
      // constructor(2) => FinishPhase
      const finishRedeemer = new Constr(2, [backerDatum]);
      const finishRedeemerData = Data.to(finishRedeemer);
    
      const supportTokenUnit = toUnit(policyId, "support_token");
      const rewardTokenUnit  = toUnit(policyId, "reward_token");
      const mintedAssets = {
        [supportTokenUnit]: -1n,
        [rewardTokenUnit]:  1n,
      };
    
      // e.g. find the backer's UTxOs with the support token
      const backerUtxos = await lucid.utxosAtWithUnit(scriptAddress, supportTokenUnit);
    
      const tx = await lucid
        .newTx()
        .collectFrom(backerUtxos, finishRedeemerData)
        .mintAssets(mintedAssets, finishRedeemerData)
        .attach.MintingPolicy({ type: "PlutusV3", script: script.Crowdfunding })
        .pay.ToContract(
          scriptAddress,
          { kind: "inline", value: Data.to(backerDatum) },
          { [rewardTokenUnit]: 1n }
        )
        .complete();
    
      const txHash = await submitTx(tx);
      handleSuccess(`Finished phase: ${txHash}`);
      return txHash;
    }
    
    /*******************************************
     * 4) Spend Validator Transactions
     *******************************************/
    export async function cancelCampaign(
      { lucid, wallet }: WalletConnection,
      spendValidator: Validator,
      campaignUTxO: UTxO,
      updatedDatum: CampaignParams
    ) {
      if (!lucid || !wallet) throw new Error("Lucid or Wallet not initialized");
      const cancelRedeemer = new Constr(0, []);
      const datumConstr = buildMovieCampaignDatum(updatedDatum);
    
      const tx = await lucid
        .newTx()
        .collectFrom([campaignUTxO], Data.to(cancelRedeemer))
        .attach.SpendingValidator(spendValidator)
        .pay.ToContract(
          campaignUTxO.address,
          { kind: "inline", value: Data.to(datumConstr) },
          {}
        )
        .complete();
    
      const txHash = await submitTx(tx);
      handleSuccess(`Campaign canceled: ${txHash}`);
      return txHash;
    }
    
    export async function advancePhase(
      { lucid, wallet }: WalletConnection,
      spendValidator: Validator,
      campaignUTxO: UTxO,
      updatedDatum: CampaignParams
    ) {
      if (!lucid || !wallet) throw new Error("Lucid or Wallet not initialized");
      const advRedeemer = new Constr(1, []);
      const advRedeemerData = Data.to(advRedeemer);
    
      const datumConstr = buildMovieCampaignDatum(updatedDatum);
    
      const tx = await lucid
        .newTx()
        .collectFrom([campaignUTxO], advRedeemerData)
        .attach.SpendingValidator(spendValidator)
        .pay.ToContract(
          campaignUTxO.address,
          { kind: "inline", value: Data.to(datumConstr) },
          {}
        )
        .complete();
    
      const txHash = await submitTx(tx);
      handleSuccess(`Phase advanced: ${txHash}`);
      return txHash;
    }
    
    export async function refundBacker(
      { lucid, wallet }: WalletConnection,
      spendValidator: Validator,
      campaignUTxO: UTxO,
      backerUTxOs: UTxO[],
      backerAddress: string
    ) {
      if (!lucid || !wallet) throw new Error("Lucid or Wallet not initialized");
      const refundRedeemer = new Constr(2, []);
      const refundRedeemerData = Data.to(refundRedeemer);
    
      let totalLovelace = 0n;
      backerUTxOs.forEach((u) => {
        totalLovelace += u.assets.lovelace || 0n;
      });
    
      const tx = await lucid
        .newTx()
        .readFrom([campaignUTxO])
        .collectFrom(backerUTxOs, refundRedeemerData)
        .attach.SpendingValidator(spendValidator)
        .pay.ToAddress(backerAddress, { lovelace: totalLovelace })
        .complete();
    
      const txHash = await submitTx(tx);
      handleSuccess(`Refunded backer(s): ${txHash}`);
      return txHash;
    }
    
    export async function distributeRewards(
      { lucid, wallet }: WalletConnection,
      spendValidator: Validator,
      campaignUTxO: UTxO,
      updatedDatum: CampaignParams
    ) {
      if (!lucid || !wallet) throw new Error("Lucid or Wallet not initialized");
      const distRedeemer = new Constr(4, []);
      const distRedeemerData = Data.to(distRedeemer);
    
      const datumConstr = buildMovieCampaignDatum(updatedDatum);
    
      const tx = await lucid
        .newTx()
        .collectFrom([campaignUTxO], distRedeemerData)
        .attach.SpendingValidator(spendValidator)
        .pay.ToContract(
          campaignUTxO.address,
          { kind: "inline", value: Data.to(datumConstr) },
          {}
        )
        .complete();
    
      const txHash = await submitTx(tx);
      handleSuccess(`Rewards distributed: ${txHash}`);
      return txHash;
    }
    
    export async function concludeCampaign(
      { lucid, wallet }: WalletConnection,
      spendValidator: Validator,
      campaignUTxO: UTxO,
      updatedDatum: CampaignParams
    ) {
      if (!lucid || !wallet) throw new Error("Lucid or Wallet not initialized");
      const concRedeemer = new Constr(3, []);
      const concRedeemerData = Data.to(concRedeemer);
    
      const datumConstr = buildMovieCampaignDatum(updatedDatum);
    
      const tx = await lucid
        .newTx()
        .collectFrom([campaignUTxO], concRedeemerData)
        .attach.SpendingValidator(spendValidator)
        .pay.ToContract(
          campaignUTxO.address,
          { kind: "inline", value: Data.to(datumConstr) },
          {}
        )
        .complete();
    
      const txHash = await submitTx(tx);
      handleSuccess(`Campaign concluded: ${txHash}`);
      return txHash;
    }
    
