//! Regenerate the `SOLANA_CONFIDENTIAL_*` fixtures used by the
//! "confidential bundle profile" tests in
//! `test/mpp/methods/solana_integration_test.exs`.
//!
//! Two subcommands:
//!
//!   * `setup`   — one-off (and idempotent) devnet state: a Token-2022 mint
//!                 with the ConfidentialTransfer extension, a recipient
//!                 confidential account, and two funded sender confidential
//!                 accounts. Writes the stable exports to
//!                 `$MPP_CONFIDENTIAL_DIR/exports.env` (mode 600) because one
//!                 of them (the recipient ElGamal secret) is a secret.
//!   * `bundles` — regenerate both signed bundles against a fresh blockhash
//!                 and print the two `export …_BUNDLE_JSON=…` lines on stdout.
//!                 Bundles expire with the blockhash (~60-90 s on devnet), so
//!                 this runs immediately before `mix test`.
//!   * `bundles-json`
//!               — the same pair as a JSON object, which is what the test's
//!                 `SOLANA_CONFIDENTIAL_BUNDLE_CMD` hook consumes so each
//!                 confidential test gets bundles minted seconds earlier.
//!   * `status`  — print on-chain state without sending anything.
//!
//! Bundle shape (what `MPP.Methods.Solana.Confidential` accepts):
//!
//!   1. create + verify the ciphertext-commitment-equality proof context
//!   2. create + verify the batched-grouped-ciphertext-3-handles-validity
//!      proof context
//!   3. create the spl-record account and write the first range-proof chunk
//!   4. write the remaining chunk(s); the last write also creates the range
//!      proof context and verifies it *from* the record account
//!   5. the ConfidentialTransfer instruction followed by the three
//!      close-context instructions and the record close
//!
//! Every transaction uses the MPP payer as fee payer and leaves signature slot
//! 0 empty (`MPP.Methods.Solana` co-signs). Every proof context and record
//! account is authored by, and returns its rent to, that same fee payer —
//! `MPP.Methods.Solana.Confidential` rejects any other arrangement.
//!
//! Adapted from solana-foundation/Confidential-Balances-Sample
//! (https://github.com/solana-foundation/Confidential-Balances-Sample), which
//! is also where the zk-sdk 4.0 / 6.0.1 byte-cast boundary and the
//! record-account staging of the oversized U128 range proof come from.

use std::error::Error;
use std::fs;
use std::path::{Path, PathBuf};

use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine as _;
use solana_address::Address;
use solana_client::rpc_client::RpcClient;
use solana_commitment_config::CommitmentConfig;
use solana_sdk::{
    hash::Hash,
    instruction::Instruction,
    message::Message,
    pubkey::Pubkey,
    signature::{Keypair, Signature, Signer},
    transaction::Transaction,
};
use solana_system_interface::instruction as system_instruction;
use solana_zk_elgamal_proof_interface::{
    instruction::{close_context_state, ContextStateInfo, ProofInstruction},
    proof_data::{
        BatchedGroupedCiphertext3HandlesValidityProofContext, BatchedRangeProofContext,
        CiphertextCommitmentEqualityProofContext, PubkeyValidityProofContext,
    },
    state::ProofContextState,
};
use solana_zk_sdk::{
    encryption::{
        auth_encryption::{AeCiphertext, AeKey},
        elgamal::{ElGamalCiphertext, ElGamalKeypair, ElGamalPubkey},
    },
    zk_elgamal_proof_program::pubkey_validity::build_pubkey_validity_proof_data,
};
use solana_zk_sdk_pod::encryption::elgamal::{
    PodElGamalCiphertext as PodElGamalCiphertextV6, PodElGamalPubkey as PodElGamalPubkeyV6,
};
use spl_associated_token_account::{
    get_associated_token_address_with_program_id, instruction::create_associated_token_account,
};
use spl_token_2022::{
    extension::{
        confidential_transfer::{
            instruction::{
                apply_pending_balance as apply_pending_balance_instruction, configure_account,
                deposit, initialize_mint as initialize_confidential_mint, inner_transfer,
                BatchedGroupedCiphertext3HandlesValidityProofData, BatchedRangeProofU128Data,
                CiphertextCommitmentEqualityProofData,
                PubkeyValidityProofData as PubkeyValidityProofDataLegacy,
            },
            ConfidentialTransferAccount, ConfidentialTransferMint,
        },
        BaseStateWithExtensions, ExtensionType, StateWithExtensions,
    },
    instruction::{initialize_mint as initialize_mint_base, mint_to, reallocate},
    solana_zk_sdk::encryption::pod::{
        auth_encryption::PodAeCiphertext as PodAeCiphertextLegacy,
        elgamal::{
            PodElGamalCiphertext as PodElGamalCiphertextLegacy,
            PodElGamalPubkey as PodElGamalPubkeyLegacy,
        },
    },
    state::{Account as TokenAccount, Mint},
};
use spl_token_confidential_transfer_proof_extraction::instruction::ProofLocation;
use spl_token_confidential_transfer_proof_generation::transfer::transfer_split_proof_data;

type Res<T> = Result<T, Box<dyn Error>>;

const ZK_PROOF_PROGRAM_ID: Pubkey =
    solana_sdk::pubkey!("ZkE1Gama1Proof11111111111111111111111111111");

/// `RecordData::WRITABLE_START_INDEX` — 1-byte version + 32-byte authority.
const RECORD_PROOF_OFFSET: u32 = 33;
/// The first record tx also carries create_account + initialize, so it writes less.
const RECORD_FIRST_CHUNK: usize = 750;
const RECORD_WRITE_CHUNK: usize = 900;

const DECIMALS: u8 = 2;
/// Challenged amount (base units) — the success bundle transfers exactly this.
const AMOUNT: u64 = 1_000;
/// The wrong-amount bundle transfers this instead, so the recipient pending
/// balance delta cannot match the challenge.
const WRONG_AMOUNT: u64 = 2_500;
/// Public units minted (then deposited) whenever a sender runs low.
const TOPUP_UNITS: u64 = 200_000;
/// `ConfigureAccount`'s maximum_pending_balance_credit_counter: how many
/// incoming transfers a recipient may accumulate before it must apply them.
const MAX_PENDING_BALANCE_CREDIT_COUNTER: u64 = 65_536;

fn main() -> Res<()> {
    let command = std::env::args().nth(1).unwrap_or_else(|| "bundles".into());
    let rpc_url = std::env::var("SOLANA_RPC_URL")
        .or_else(|_| std::env::var("SOLANA_DEVNET_RPC_URL"))
        .map_err(|_| "SOLANA_RPC_URL is not set (source ~/.secrets first)")?;
    let client = RpcClient::new_with_commitment(rpc_url, CommitmentConfig::confirmed());
    let payer = load_payer()?;

    match command.as_str() {
        "setup" => setup(&client, &payer),
        "bundles" => bundles(&client, &payer, Format::Exports),
        "bundles-json" => bundles(&client, &payer, Format::Json),
        "status" => status(&client, &payer),
        other => Err(format!(
            "unknown command {other:?}; use setup | bundles | bundles-json | status"
        )
        .into()),
    }
}

// ---------------------------------------------------------------------------
// key material
// ---------------------------------------------------------------------------

fn home() -> Res<PathBuf> {
    Ok(PathBuf::from(std::env::var("HOME")?))
}

fn state_dir() -> Res<PathBuf> {
    let dir = match std::env::var("MPP_CONFIDENTIAL_DIR") {
        Ok(dir) => PathBuf::from(dir),
        Err(_) => home()?.join(".config/solana/mpp-confidential"),
    };
    fs::create_dir_all(&dir)?;
    Ok(dir)
}

/// The MPP fee payer: whatever `SOLANA_PRIVATE_KEY` names, so the fixtures and
/// the test agree on the fee payer without the key ever being printed.
fn load_payer() -> Res<Keypair> {
    if let Ok(raw) = std::env::var("SOLANA_PRIVATE_KEY") {
        return keypair_from_str(raw.trim());
    }
    let path = home()?.join(".config/solana/mpp-devnet.json");
    keypair_from_str(fs::read_to_string(path)?.trim())
}

/// The same three formats, with the same precedence, as the integration
/// test's `decode_seed!/1`: a Solana CLI JSON byte array, a 64- or 128-digit
/// hex seed (optionally `0x`-prefixed), else base58.
fn keypair_from_str(raw: &str) -> Res<Keypair> {
    let hex = raw.strip_prefix("0x").unwrap_or(raw);
    let bytes = if raw.starts_with('[') {
        serde_json::from_str::<Vec<u8>>(raw)?
    } else if hex.bytes().all(|b| b.is_ascii_hexdigit()) && (hex.len() == 64 || hex.len() == 128) {
        (0..hex.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&hex[i..i + 2], 16))
            .collect::<Result<Vec<u8>, _>>()?
    } else {
        bs58::decode(raw)
            .into_vec()
            .map_err(|e| format!("key is neither JSON, 64/128-digit hex, nor base58: {e}"))?
    };
    if bytes.len() != 32 && bytes.len() != 64 {
        return Err(format!("expected a 32- or 64-byte key, got {}", bytes.len()).into());
    }
    let mut seed = [0u8; 32];
    seed.copy_from_slice(&bytes[0..32]);
    Ok(Keypair::new_from_array(seed))
}

fn load_or_create_keypair(path: &Path) -> Res<Keypair> {
    if path.exists() {
        return keypair_from_str(fs::read_to_string(path)?.trim());
    }
    let keypair = Keypair::new();
    let bytes: Vec<u8> = keypair
        .secret_bytes()
        .iter()
        .copied()
        .chain(keypair.pubkey().to_bytes())
        .collect();
    write_owner_only(path, &serde_json::to_string(&bytes)?)?;
    eprintln!("• generated {} -> {}", path.display(), keypair.pubkey());
    Ok(keypair)
}

/// Write a secret-bearing file that is owner-only from its first byte: the
/// file is created with mode 0600 (never at the umask default and chmod'ed
/// afterwards), and an existing file is re-tightened after the write.
fn write_owner_only(path: &Path, contents: &str) -> Res<()> {
    use std::io::Write as _;
    let mut file = owner_only_options()
        .write(true)
        .create(true)
        .truncate(true)
        .open(path)?;
    file.write_all(contents.as_bytes())?;
    set_owner_only(path)
}

#[cfg(unix)]
fn owner_only_options() -> fs::OpenOptions {
    use std::os::unix::fs::OpenOptionsExt;
    let mut options = fs::OpenOptions::new();
    options.mode(0o600);
    options
}

#[cfg(not(unix))]
fn owner_only_options() -> fs::OpenOptions {
    fs::OpenOptions::new()
}

#[cfg(unix)]
fn set_owner_only(path: &Path) -> Res<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
    Ok(())
}

#[cfg(not(unix))]
fn set_owner_only(_path: &Path) -> Res<()> {
    Ok(())
}

struct Fixtures {
    mint: Keypair,
    recipient: Keypair,
    sender_a: Keypair,
    sender_b: Keypair,
}

fn load_fixtures() -> Res<Fixtures> {
    let dir = state_dir()?;
    Ok(Fixtures {
        mint: load_or_create_keypair(&dir.join("mint.json"))?,
        recipient: load_or_create_keypair(&dir.join("recipient.json"))?,
        sender_a: load_or_create_keypair(&dir.join("sender-a.json"))?,
        sender_b: load_or_create_keypair(&dir.join("sender-b.json"))?,
    })
}

// ---------------------------------------------------------------------------
// setup
// ---------------------------------------------------------------------------

fn setup(client: &RpcClient, payer: &Keypair) -> Res<()> {
    let fixtures = load_fixtures()?;
    let mint = fixtures.mint.pubkey();

    if account_missing(client, &mint)? {
        create_confidential_mint(client, payer, &fixtures.mint)?;
    } else {
        eprintln!("• mint {mint} already exists");
    }

    let owners = [
        ("recipient", &fixtures.recipient),
        ("sender-a", &fixtures.sender_a),
        ("sender-b", &fixtures.sender_b),
    ];

    let mut create_atas = Vec::new();
    for (label, owner) in owners {
        let address = token_account(&owner.pubkey(), &mint);
        if account_missing(client, &address)? {
            eprintln!("• creating {label} token account {address}");
            create_atas.push(create_associated_token_account(
                &payer.pubkey(),
                &owner.pubkey(),
                &mint,
                &spl_token_2022::id(),
            ));
        }
    }
    if !create_atas.is_empty() {
        send(client, &create_atas, &[payer], &payer.pubkey())?;
    }

    for (label, owner) in owners {
        if confidential_extension(client, &token_account(&owner.pubkey(), &mint)).is_err() {
            eprintln!("• configuring {label} for confidential transfers");
            configure_confidential_account(client, payer, owner, &mint)?;
        }
    }

    ensure_available(client, payer, &fixtures.sender_a, &mint, AMOUNT)?;
    ensure_available(client, payer, &fixtures.sender_b, &mint, WRONG_AMOUNT)?;

    let recipient_ta = token_account(&fixtures.recipient.pubkey(), &mint);
    let recipient_elgamal = derive_elgamal(&fixtures.recipient, &recipient_ta)?;

    let exports = format!(
        "export SOLANA_CONFIDENTIAL_MINT=\"{mint}\"\n\
         export SOLANA_CONFIDENTIAL_RECIPIENT=\"{}\"\n\
         export SOLANA_CONFIDENTIAL_ELGAMAL_SECRET_KEY=\"{}\"\n\
         export SOLANA_CONFIDENTIAL_AMOUNT=\"{AMOUNT}\"\n\
         export SOLANA_CONFIDENTIAL_DECIMALS=\"{DECIMALS}\"\n",
        fixtures.recipient.pubkey(),
        BASE64.encode(recipient_elgamal.secret().as_bytes()),
    );

    let path = state_dir()?.join("exports.env");
    write_owner_only(&path, &exports)?;

    eprintln!("\n✅ setup complete");
    eprintln!("   mint      {mint}");
    eprintln!("   recipient {}", fixtures.recipient.pubkey());
    eprintln!("   sender-a  {} (success bundle)", fixtures.sender_a.pubkey());
    eprintln!("   sender-b  {} (wrong-amount bundle)", fixtures.sender_b.pubkey());
    eprintln!(
        "\n   stable exports written to {} (contains the recipient ElGamal secret)",
        path.display()
    );
    Ok(())
}

fn create_confidential_mint(client: &RpcClient, payer: &Keypair, mint: &Keypair) -> Res<()> {
    let space = ExtensionType::try_calculate_account_len::<Mint>(&[
        ExtensionType::ConfidentialTransferMint,
    ])?;
    let rent = client.get_minimum_balance_for_rent_exemption(space)?;

    // Auditor key is generated and discarded: the auditor ciphertexts ride in
    // the transfer instruction either way, and nothing in MPP reads them.
    let auditor = ElGamalKeypair::new_rand();
    let auditor_pod: PodElGamalPubkeyLegacy =
        PodElGamalPubkeyLegacy::from(auditor.pubkey().to_bytes());

    let instructions = [
        system_instruction::create_account(
            &payer.pubkey(),
            &mint.pubkey(),
            rent,
            space as u64,
            &spl_token_2022::id(),
        ),
        initialize_confidential_mint(
            &spl_token_2022::id(),
            &mint.pubkey(),
            None,
            true, // auto_approve_new_accounts — MPP requires an approved account
            Some(auditor_pod),
        )?,
        initialize_mint_base(
            &spl_token_2022::id(),
            &mint.pubkey(),
            &payer.pubkey(),
            None,
            DECIMALS,
        )?,
    ];

    let signature = send(client, &instructions, &[payer, mint], &payer.pubkey())?;
    eprintln!("• mint {} created: {signature}", mint.pubkey());
    Ok(())
}

fn configure_confidential_account(
    client: &RpcClient,
    payer: &Keypair,
    authority: &Keypair,
    mint: &Pubkey,
) -> Res<()> {
    let address = token_account(&authority.pubkey(), mint);
    let elgamal = derive_elgamal(authority, &address)?;
    let aes = derive_aes(authority, &address)?;

    let decryptable_balance = PodAeCiphertextLegacy::from(aes.encrypt(0u64).to_bytes());
    let proof_data = build_pubkey_validity_proof_data(&elgamal)
        .map_err(|e| format!("pubkey validity proof: {e}"))?;

    let context = Keypair::new();
    let size = std::mem::size_of::<ProofContextState<PubkeyValidityProofContext>>();
    let rent = client.get_minimum_balance_for_rent_exemption(size)?;

    let mut instructions = vec![
        reallocate(
            &spl_token_2022::id(),
            &address,
            &payer.pubkey(),
            &authority.pubkey(),
            &[&authority.pubkey()],
            &[ExtensionType::ConfidentialTransferAccount],
        )?,
        system_instruction::create_account(
            &payer.pubkey(),
            &context.pubkey(),
            rent,
            size as u64,
            &ZK_PROOF_PROGRAM_ID,
        ),
        ProofInstruction::VerifyPubkeyValidity.encode_verify_proof(
            Some(ContextStateInfo {
                context_state_account: &address_of(&context.pubkey()),
                context_state_authority: &address_of(&payer.pubkey()),
            }),
            &proof_data,
        ),
    ];

    let location: ProofLocation<PubkeyValidityProofDataLegacy> =
        ProofLocation::ContextStateAccount(&context.pubkey());
    instructions.extend(configure_account(
        &spl_token_2022::id(),
        &address,
        mint,
        &decryptable_balance,
        MAX_PENDING_BALANCE_CREDIT_COUNTER,
        &authority.pubkey(),
        &[],
        location,
    )?);

    let signature = send(
        client,
        &instructions,
        &[payer, authority, &context],
        &payer.pubkey(),
    )?;
    eprintln!("  configured {address}: {signature}");
    Ok(())
}

/// Mint, deposit and apply whenever the sender's confidential available
/// balance can no longer cover a bundle.
fn ensure_available(
    client: &RpcClient,
    payer: &Keypair,
    sender: &Keypair,
    mint: &Pubkey,
    needed: u64,
) -> Res<()> {
    let address = token_account(&sender.pubkey(), mint);
    let available = available_balance(client, sender, mint)?;
    if available >= needed * 2 {
        eprintln!("• {address} available balance {available} ≥ {}", needed * 2);
        return Ok(());
    }

    eprintln!("• topping up {address} (available {available})");
    send(
        client,
        &[mint_to(
            &spl_token_2022::id(),
            mint,
            &address,
            &payer.pubkey(),
            &[],
            TOPUP_UNITS,
        )?],
        &[payer],
        &payer.pubkey(),
    )?;
    send(
        client,
        &[deposit(
            &spl_token_2022::id(),
            &address,
            mint,
            TOPUP_UNITS,
            DECIMALS,
            &sender.pubkey(),
            &[&sender.pubkey()],
        )?],
        &[payer, sender],
        &payer.pubkey(),
    )?;
    apply_pending(client, payer, sender, mint)?;
    Ok(())
}

fn apply_pending(client: &RpcClient, payer: &Keypair, owner: &Keypair, mint: &Pubkey) -> Res<()> {
    let address = token_account(&owner.pubkey(), mint);
    let elgamal = derive_elgamal(owner, &address)?;
    let aes = derive_aes(owner, &address)?;

    let data = client.get_account(&address)?;
    let state = StateWithExtensions::<TokenAccount>::unpack(&data.data)?;
    let extension = state.get_extension::<ConfidentialTransferAccount>()?;

    let pending_lo = to_v6_ciphertext(&extension.pending_balance_lo)?
        .decrypt_u32(elgamal.secret())
        .ok_or("decrypt pending_balance_lo")?;
    let pending_hi = to_v6_ciphertext(&extension.pending_balance_hi)?
        .decrypt_u32(elgamal.secret())
        .ok_or("decrypt pending_balance_hi")?;
    let available = to_v6_ciphertext(&extension.available_balance)?
        .decrypt_u32(elgamal.secret())
        .ok_or("decrypt available_balance")?;

    let new_available = available as u64 + pending_lo as u64 + ((pending_hi as u64) << 16);
    let decryptable = PodAeCiphertextLegacy::from(aes.encrypt(new_available).to_bytes());
    let counter: u64 = extension.pending_balance_credit_counter.into();

    let signature = send(
        client,
        &[apply_pending_balance_instruction(
            &spl_token_2022::id(),
            &address,
            counter,
            &decryptable,
            &owner.pubkey(),
            &[&owner.pubkey()],
        )?],
        &[payer, owner],
        &payer.pubkey(),
    )?;
    eprintln!("  applied pending balance, available now {new_available}: {signature}");
    Ok(())
}

fn status(client: &RpcClient, _payer: &Keypair) -> Res<()> {
    let fixtures = load_fixtures()?;
    let mint = fixtures.mint.pubkey();
    println!("mint      {mint} (exists: {})", !account_missing(client, &mint)?);
    for (label, owner) in [
        ("recipient", &fixtures.recipient),
        ("sender-a", &fixtures.sender_a),
        ("sender-b", &fixtures.sender_b),
    ] {
        let address = token_account(&owner.pubkey(), &mint);
        let available = available_balance(client, owner, &mint).unwrap_or(0);
        println!("{label:<9} {address} available={available}");
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// bundles
// ---------------------------------------------------------------------------

/// How `bundles` reports itself: shell `export` lines for an operator, or a
/// JSON object for `SOLANA_CONFIDENTIAL_BUNDLE_CMD` inside the test.
enum Format {
    Exports,
    Json,
}

fn bundles(client: &RpcClient, payer: &Keypair, format: Format) -> Res<()> {
    let fixtures = load_fixtures()?;
    let mint = fixtures.mint.pubkey();
    if account_missing(client, &mint)? {
        return Err("mint does not exist — run `setup` first".into());
    }

    // Every settled bundle drains its sender; top up before minting so a
    // long-lived fixture set never fails mid-proof on an empty balance.
    ensure_available(client, payer, &fixtures.sender_a, &mint, AMOUNT)?;
    ensure_available(client, payer, &fixtures.sender_b, &mint, WRONG_AMOUNT)?;

    let recipient = fixtures.recipient.pubkey();
    let blockhash = client.get_latest_blockhash()?;

    let success = build_bundle(
        client,
        &payer.pubkey(),
        &fixtures.sender_a,
        &recipient,
        &mint,
        AMOUNT,
        blockhash,
    )?;
    let wrong = build_bundle(
        client,
        &payer.pubkey(),
        &fixtures.sender_b,
        &recipient,
        &mint,
        WRONG_AMOUNT,
        blockhash,
    )?;

    eprintln!(
        "• built {} + {} transactions against blockhash {blockhash} \
         (valid for roughly 60-90 s on devnet)",
        success.len(),
        wrong.len()
    );

    let success = serde_json::to_string(&success)?;
    let wrong = serde_json::to_string(&wrong)?;

    match format {
        Format::Exports => {
            println!("export SOLANA_CONFIDENTIAL_SUCCESS_BUNDLE_JSON='{success}'");
            println!("export SOLANA_CONFIDENTIAL_WRONG_AMOUNT_BUNDLE_JSON='{wrong}'");
        }
        Format::Json => println!(
            "{}",
            serde_json::json!({
                "SOLANA_CONFIDENTIAL_SUCCESS_BUNDLE_JSON": success,
                "SOLANA_CONFIDENTIAL_WRONG_AMOUNT_BUNDLE_JSON": wrong,
            })
        ),
    }
    Ok(())
}

fn build_bundle(
    client: &RpcClient,
    payer: &Pubkey,
    sender: &Keypair,
    recipient: &Pubkey,
    mint: &Pubkey,
    amount: u64,
    blockhash: Hash,
) -> Res<Vec<String>> {
    let sender_ta = token_account(&sender.pubkey(), mint);
    let recipient_ta = token_account(recipient, mint);

    let recipient_extension = confidential_extension(client, &recipient_ta)?;
    let recipient_elgamal: ElGamalPubkey = to_v6_pubkey(&recipient_extension.elgamal_pubkey)?
        .try_into()
        .map_err(|e| format!("recipient ElGamal pubkey: {e:?}"))?;

    let mint_data = client.get_account(mint)?;
    let mint_state = StateWithExtensions::<Mint>::unpack(&mint_data.data)?;
    let auditor_elgamal: Option<ElGamalPubkey> = {
        let pod: Option<PodElGamalPubkeyLegacy> = mint_state
            .get_extension::<ConfidentialTransferMint>()?
            .auditor_elgamal_pubkey
            .into();
        pod.map(|pod| -> Res<ElGamalPubkey> {
            to_v6_pubkey(&pod)?
                .try_into()
                .map_err(|e| format!("auditor ElGamal pubkey: {e:?}").into())
        })
        .transpose()?
    };

    let sender_elgamal = derive_elgamal(sender, &sender_ta)?;
    let sender_aes = derive_aes(sender, &sender_ta)?;

    let sender_extension = confidential_extension(client, &sender_ta)?;
    let available: ElGamalCiphertext = to_v6_ciphertext(&sender_extension.available_balance)?;
    let decryptable: AeCiphertext =
        to_v6_ae_ciphertext(&sender_extension.decryptable_available_balance)?;

    let proof_data = transfer_split_proof_data(
        &available,
        &decryptable,
        amount,
        &sender_elgamal,
        &sender_aes,
        &recipient_elgamal,
        auditor_elgamal.as_ref(),
    )
    .map_err(|e| format!("transfer_split_proof_data: {e}"))?;

    let payer_address = address_of(payer);
    let mut transactions: Vec<String> = Vec::new();

    // 1. equality proof context
    let equality = Keypair::new();
    let equality_size =
        std::mem::size_of::<ProofContextState<CiphertextCommitmentEqualityProofContext>>();
    transactions.push(encode(
        &[
            create_context_account(client, payer, &equality.pubkey(), equality_size)?,
            ProofInstruction::VerifyCiphertextCommitmentEquality.encode_verify_proof(
                Some(ContextStateInfo {
                    context_state_account: &address_of(&equality.pubkey()),
                    context_state_authority: &payer_address,
                }),
                &proof_data.equality_proof_data,
            ),
        ],
        payer,
        &[&equality],
        blockhash,
    )?);

    // 2. ciphertext-validity proof context
    let validity = Keypair::new();
    let validity_size = std::mem::size_of::<
        ProofContextState<BatchedGroupedCiphertext3HandlesValidityProofContext>,
    >();
    transactions.push(encode(
        &[
            create_context_account(client, payer, &validity.pubkey(), validity_size)?,
            ProofInstruction::VerifyBatchedGroupedCiphertext3HandlesValidity.encode_verify_proof(
                Some(ContextStateInfo {
                    context_state_account: &address_of(&validity.pubkey()),
                    context_state_authority: &payer_address,
                }),
                &proof_data
                    .ciphertext_validity_proof_data_with_ciphertext
                    .proof_data,
            ),
        ],
        payer,
        &[&validity],
        blockhash,
    )?);

    // 3./4. the U128 range proof does not fit in a transaction: stage it in an
    // spl-record account, then verify it *from* that account.
    let record = Keypair::new();
    let range = Keypair::new();
    let range_size = std::mem::size_of::<ProofContextState<BatchedRangeProofContext>>();
    let trailing = [
        create_context_account(client, payer, &range.pubkey(), range_size)?,
        ProofInstruction::VerifyBatchedRangeProofU128.encode_verify_proof_from_account(
            Some(ContextStateInfo {
                context_state_account: &address_of(&range.pubkey()),
                context_state_authority: &payer_address,
            }),
            &address_of(&record.pubkey()),
            RECORD_PROOF_OFFSET,
        ),
    ];
    transactions.extend(stage_range_proof(
        client,
        payer,
        &record,
        bytemuck::bytes_of(&proof_data.range_proof_data),
        &trailing,
        &[&range],
        blockhash,
    )?);

    // 5. the transfer itself, followed by every close so the fee payer gets
    //    all of its rent back inside the bundle.
    let current_plaintext = decryptable
        .decrypt(&sender_aes)
        .ok_or("decrypt sender available balance")?;
    let new_plaintext = current_plaintext
        .checked_sub(amount)
        .ok_or("sender has insufficient confidential available balance")?;
    let new_decryptable = PodAeCiphertextLegacy::from(sender_aes.encrypt(new_plaintext).to_bytes());

    let ciphertext_lo = PodElGamalCiphertextLegacy::from(
        proof_data
            .ciphertext_validity_proof_data_with_ciphertext
            .ciphertext_lo
            .0,
    );
    let ciphertext_hi = PodElGamalCiphertextLegacy::from(
        proof_data
            .ciphertext_validity_proof_data_with_ciphertext
            .ciphertext_hi
            .0,
    );

    let equality_location: ProofLocation<CiphertextCommitmentEqualityProofData> =
        ProofLocation::ContextStateAccount(&equality.pubkey());
    let validity_location: ProofLocation<BatchedGroupedCiphertext3HandlesValidityProofData> =
        ProofLocation::ContextStateAccount(&validity.pubkey());
    let range_location: ProofLocation<BatchedRangeProofU128Data> =
        ProofLocation::ContextStateAccount(&range.pubkey());

    let transfer = inner_transfer(
        &spl_token_2022::id(),
        &sender_ta,
        mint,
        &recipient_ta,
        &new_decryptable,
        &ciphertext_lo,
        &ciphertext_hi,
        &sender.pubkey(),
        &[],
        equality_location,
        validity_location,
        range_location,
    )?;

    let close = |context: &Pubkey| {
        close_context_state(
            ContextStateInfo {
                context_state_account: &address_of(context),
                context_state_authority: &payer_address,
            },
            &payer_address,
        )
    };

    transactions.push(encode(
        &[
            transfer,
            close(&equality.pubkey()),
            close(&validity.pubkey()),
            close(&range.pubkey()),
            spl_record::instruction::close_account(&record.pubkey(), payer, payer),
        ],
        payer,
        &[sender],
        blockhash,
    )?);

    Ok(transactions)
}

fn stage_range_proof(
    client: &RpcClient,
    payer: &Pubkey,
    record: &Keypair,
    proof_bytes: &[u8],
    trailing: &[Instruction],
    trailing_signers: &[&Keypair],
    blockhash: Hash,
) -> Res<Vec<String>> {
    if proof_bytes.is_empty() {
        return Err("range proof had no bytes to stage".into());
    }
    let space = proof_bytes.len() + RECORD_PROOF_OFFSET as usize;
    let rent = client.get_minimum_balance_for_rent_exemption(space)?;

    let first_len = proof_bytes.len().min(RECORD_FIRST_CHUNK);
    let (first, rest) = proof_bytes.split_at(first_len);

    let mut transactions = vec![encode(
        &[
            system_instruction::create_account(
                payer,
                &record.pubkey(),
                rent,
                space as u64,
                &spl_record::id(),
            ),
            spl_record::instruction::initialize(&record.pubkey(), payer),
            spl_record::instruction::write(&record.pubkey(), payer, 0, first),
        ],
        payer,
        &[record],
        blockhash,
    )?];

    let mut offset = first.len();
    let mut chunks = rest.chunks(RECORD_WRITE_CHUNK).peekable();
    let mut attached = false;
    while let Some(chunk) = chunks.next() {
        let mut instructions = vec![spl_record::instruction::write(
            &record.pubkey(),
            payer,
            offset as u64,
            chunk,
        )];
        let mut signers: Vec<&Keypair> = Vec::new();
        if chunks.peek().is_none() {
            instructions.extend_from_slice(trailing);
            signers.extend_from_slice(trailing_signers);
            attached = true;
        }
        transactions.push(encode(&instructions, payer, &signers, blockhash)?);
        offset += chunk.len();
    }

    if !attached {
        transactions.push(encode(trailing, payer, trailing_signers, blockhash)?);
    }

    Ok(transactions)
}

fn create_context_account(
    client: &RpcClient,
    payer: &Pubkey,
    context: &Pubkey,
    size: usize,
) -> Res<Instruction> {
    let rent = client.get_minimum_balance_for_rent_exemption(size)?;
    Ok(system_instruction::create_account(
        payer,
        context,
        rent,
        size as u64,
        &ZK_PROOF_PROGRAM_ID,
    ))
}

/// Serialize a legacy transaction whose fee-payer signature slot stays empty
/// for `MPP.Methods.Solana` to fill.
fn encode(
    instructions: &[Instruction],
    payer: &Pubkey,
    signers: &[&Keypair],
    blockhash: Hash,
) -> Res<String> {
    let message = Message::new_with_blockhash(instructions, Some(payer), &blockhash);
    let mut transaction = Transaction::new_unsigned(message);
    if !signers.is_empty() {
        transaction.partial_sign(signers, blockhash);
    }
    if transaction.signatures[0] != Signature::default() {
        return Err("fee payer signature slot must stay empty".into());
    }
    let bytes = bincode::serialize(&transaction)?;
    if bytes.len() > 1232 {
        return Err(format!("transaction is {} bytes, over the 1232 limit", bytes.len()).into());
    }
    Ok(BASE64.encode(bytes))
}

// ---------------------------------------------------------------------------
// chain helpers
// ---------------------------------------------------------------------------

fn send(
    client: &RpcClient,
    instructions: &[Instruction],
    signers: &[&Keypair],
    payer: &Pubkey,
) -> Res<Signature> {
    let blockhash = client.get_latest_blockhash()?;
    let transaction = Transaction::new_signed_with_payer(
        instructions,
        Some(payer),
        &signers.to_vec(),
        blockhash,
    );
    Ok(client.send_and_confirm_transaction(&transaction)?)
}

fn token_account(owner: &Pubkey, mint: &Pubkey) -> Pubkey {
    get_associated_token_address_with_program_id(owner, mint, &spl_token_2022::id())
}

fn account_missing(client: &RpcClient, address: &Pubkey) -> Res<bool> {
    Ok(client
        .get_account_with_commitment(address, CommitmentConfig::confirmed())?
        .value
        .is_none())
}

fn confidential_extension(
    client: &RpcClient,
    address: &Pubkey,
) -> Res<ConfidentialTransferAccount> {
    let data = client.get_account(address)?;
    let state = StateWithExtensions::<TokenAccount>::unpack(&data.data)?;
    Ok(*state.get_extension::<ConfidentialTransferAccount>()?)
}

fn available_balance(client: &RpcClient, owner: &Keypair, mint: &Pubkey) -> Res<u64> {
    let address = token_account(&owner.pubkey(), mint);
    let extension = confidential_extension(client, &address)?;
    let elgamal = derive_elgamal(owner, &address)?;
    let available = to_v6_ciphertext(&extension.available_balance)?
        .decrypt_u32(elgamal.secret())
        .ok_or("decrypt available_balance")?;
    Ok(available as u64)
}

/// Token-2022 derives a confidential account's ElGamal and AES keys from the
/// owner's signature over the token-account address; every reader and writer
/// of that account must derive them the same way.
fn derive_elgamal(owner: &Keypair, address: &Pubkey) -> Res<ElGamalKeypair> {
    ElGamalKeypair::new_from_signer(owner, &address.to_bytes())
        .map_err(|e| format!("derive ElGamal keypair for {address}: {e}").into())
}

fn derive_aes(owner: &Keypair, address: &Pubkey) -> Res<AeKey> {
    AeKey::new_from_signer(owner, &address.to_bytes())
        .map_err(|e| format!("derive AES key for {address}: {e}").into())
}

fn address_of(pubkey: &Pubkey) -> Address {
    Address::from(pubkey.to_bytes())
}

// zk-sdk 4.0 -> 6.0.1 byte casts. The POD wire formats are identical; only the
// Rust types are version-tagged.

fn to_v6_pubkey(legacy: &PodElGamalPubkeyLegacy) -> Res<PodElGamalPubkeyV6> {
    let bytes: [u8; 32] = bytemuck::bytes_of(legacy)
        .try_into()
        .map_err(|_| "PodElGamalPubkey size")?;
    Ok(PodElGamalPubkeyV6(bytes))
}

fn to_v6_ciphertext(legacy: &PodElGamalCiphertextLegacy) -> Res<ElGamalCiphertext> {
    let bytes: [u8; 64] = bytemuck::bytes_of(legacy)
        .try_into()
        .map_err(|_| "PodElGamalCiphertext size")?;
    PodElGamalCiphertextV6(bytes)
        .try_into()
        .map_err(|e| format!("decode ElGamalCiphertext: {e:?}").into())
}

fn to_v6_ae_ciphertext(legacy: &PodAeCiphertextLegacy) -> Res<AeCiphertext> {
    let bytes: [u8; 36] = bytemuck::bytes_of(legacy)
        .try_into()
        .map_err(|_| "PodAeCiphertext size")?;
    AeCiphertext::from_bytes(&bytes).ok_or_else(|| "decode AeCiphertext bytes".into())
}
