#[allow(duplicate_alias, lint(public_entry))]
module ssui::ssui {
    use sui::balance;
    use sui::coin::{Self, Coin, TreasuryCap};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::event;
    use sui::object::{Self, UID, ID};
    use sui::url;
    use sui::kiosk::{Self, Kiosk};
    use std::option;
    use std::string;
    use std::ascii;
    use std::vector;
    
    // ==================== Error Codes ====================
    const ERROR_NOT_OWNER: u64 = 1;
    const ERROR_INSUFFICIENT_BALANCE: u64 = 2;
    const ERROR_ZERO_ADDRESS: u64 = 3;
    const ERROR_NOT_ALLOWLISTED: u64 = 4;
    const ERROR_ALLOWLIST_ENABLED: u64 = 5;
    const ERROR_ALLOWLIST_DISABLED: u64 = 6;
    const ERROR_ALREADY_ALLOWLISTED: u64 = 7;
    const ERROR_NOT_ALLOWLISTED_REMOVE: u64 = 8;
    const ERROR_TIMELOCK_NOT_READY: u64 = 9;
    const ERROR_NO_PENDING_ACTION: u64 = 10;
    const ERROR_INVALID_THRESHOLD: u64 = 11;
    const ERROR_ALREADY_SIGNED: u64 = 12;
    const ERROR_NOT_MULTISIG_SIGNER: u64 = 13;
    
    // ==================== Constants ====================
    // 9 decimals: 1 SSUI = 1_000_000_000 raw units (like SUI/MIST). Total 1.1B SSUI.
    const DECIMALS: u8 = 9;
    const TOTAL_SUPPLY: u64 = 1_100_000_000_000_000_000; // 1.1 billion SSUI (with 9 decimals)
    const CREATOR_SUPPLY: u64 = 1_000_000_000_000_000_000; // 1 billion SSUI to creator
    const CONTRACT_SUPPLY: u64 = 100_000_000_000_000_000; // 100 million SSUI to matrix platform (contract pool)
    const LOGO_URL: vector<u8> = b"https://i.postimg.cc/1X6mTW3h/ssui.png";
    
    // Exchange and project integration constants
    const MAX_FEE_BPS: u64 = 10000; // 100% in basis points
    const DEFAULT_TRANSFER_FEE_BPS: u64 = 0; // 0% default transfer fee

    // ==================== Production Security Constants ====================
    const TIMELOCK_DURATION_MS: u64 = 172800000; // 48 hours in milliseconds (2 days)
    const MAX_MULTISIG_SIGNERS: u64 = 10; // Maximum number of multisig signers

    // ==================== Structs ====================
    
    public struct SSUI has drop {}

    public struct AdminCap has key, store {
        id: UID,
        owner: address,
    }

    /// Token registry - stores only treasury cap and stats
    /// CoinMetadata is stored as a SEPARATE shared object
    public struct TokenRegistry has key, store {
        id: UID,
        treasury_cap: TreasuryCap<SSUI>,
        total_minted: u64,
        total_burned: u64,
        metadata_id: ID, // Store the ID of the shared CoinMetadata
        contract_supply_balance: balance::Balance<SSUI>, // Pre-allocated 100M tokens for matrix platform (no mint on register/upgrade)
        authorized_minters: vector<address>, // Addresses authorized to take from contract supply
        transfer_fee_bps: u64, // Transfer fee in basis points (0.01% = 1 bps)
        fee_recipient: address, // Address to receive transfer fees
        is_paused: bool, // Emergency pause functionality
        total_fees_collected: u64, // Track total fees collected
    }

    // ==================== Exchange Integration Structs ====================

    /// Transfer Allowlist - Optional KYC-compatible transfer restrictions
    /// When enabled, only allowlisted addresses can receive tokens
    public struct TransferAllowlist has key, store {
        id: UID,
        enabled: bool,
        allowlist: vector<address>,
        admin_cap_id: ID, // Reference to AdminCap for authorization
    }

    /// Kiosk Listing - For marketplace integration
    public struct KioskListing has key, store {
        id: UID,
        kiosk_id: ID,
        listing_count: u64,
    }

    /// Display Configuration - Rich metadata for wallets and explorers
    public struct DisplayConfig has key, store {
        id: UID,
        display_id: ID,
    }

    // ==================== Production Security Structs ====================

    /// Multisig Configuration - Multiple signers required for critical operations
    public struct MultisigConfig has key, store {
        id: UID,
        signers: vector<address>,
        threshold: u64, // Number of signatures required
        nonce: u64, // Prevents replay attacks
    }

    /// Pending Multisig Action - Tracks pending actions requiring signatures
    public struct PendingAction has key, store {
        id: UID,
        action_type: u8, // 1=transfer_ownership, 2=set_fee, 3=pause, 4=add_minter
        target_address: address,
        amount: u64,
        execute_after: u64, // Timestamp when action can be executed
        signatures: vector<address>, // Addresses that have signed
        created_at: u64,
    }

    /// Timelocked Action - Time-delayed execution for critical operations
    public struct TimelockedAction has key, store {
        id: UID,
        action_type: u8,
        target_address: address,
        amount: u64,
        execute_after: u64,
        created_at: u64,
        executed: bool,
    }

    // ==================== Events ====================
    
    public struct BurnEvent has copy, drop {
        account: address,
        amount: u64,
    }

    public struct TransferEvent has copy, drop {
        from: address,
        to: address,
        amount: u64,
        fee: u64,
    }

    public struct FeeCollectedEvent has copy, drop {
        recipient: address,
        amount: u64,
    }

    public struct PauseEvent has copy, drop {
        paused: bool,
        reason: string::String,
    }

    public struct MetadataCreatedEvent has copy, drop {
        metadata_id: ID,
        symbol: ascii::String,
        name: string::String,
        decimals: u8,
        logo_url: vector<u8>,
    }

    // ==================== Exchange Integration Events ====================

    public struct AllowlistUpdatedEvent has copy, drop {
        action: string::String, // "add", "remove", "enable", "disable"
        address: address,
        enabled: bool,
    }

    public struct KioskListedEvent has copy, drop {
        kiosk_id: ID,
        amount: u64,
        price: u64,
    }

    public struct DisplayConfiguredEvent has copy, drop {
        display_id: ID,
        name: string::String,
        description: string::String,
        project_url: string::String,
    }

    // ==================== Production Security Events ====================

    public struct MultisigActionCreatedEvent has copy, drop {
        action_id: ID,
        action_type: u8,
        target_address: address,
        amount: u64,
        execute_after: u64,
    }

    public struct MultisigActionSignedEvent has copy, drop {
        action_id: ID,
        signer: address,
        signature_count: u64,
        threshold: u64,
    }

    public struct MultisigActionExecutedEvent has copy, drop {
        action_id: ID,
        action_type: u8,
        executed_by: address,
    }

    public struct TimelockCreatedEvent has copy, drop {
        action_id: ID,
        action_type: u8,
        execute_after: u64,
    }

    public struct TimelockExecutedEvent has copy, drop {
        action_id: ID,
        action_type: u8,
        executed_by: address,
    }

    // ==================== Init Function ====================

    /// Initialize the token contract
    #[allow(deprecated_usage, unused_let_mut)]
    fun init(witness: SSUI, ctx: &mut TxContext) {
        let sender = tx_context::sender(ctx);
        
        // Create treasury cap and metadata using create_currency
        let (treasury_cap, metadata) = coin::create_currency<SSUI>(
            witness,
            DECIMALS, // 9 decimals: 1 SSUI = 1_000_000_000 raw (matches SUI/MIST)
            b"SSUI",
            b"SSUI",
            b"SuperSui Token - The native token for the SuperSUI platform",
            option::some(url::new_unsafe_from_bytes(LOGO_URL)),
            ctx
        );

        // Get metadata info BEFORE moving it
        let metadata_id = object::id(&metadata);
        let symbol = coin::get_symbol(&metadata);
        let name = coin::get_name(&metadata);
        let decimals = coin::get_decimals(&metadata);

        // 🚨🚨🚨 CRITICAL FIX: Share the CoinMetadata as a separate object
        transfer::public_share_object(metadata);

        // Emit event with metadata info for easy discovery
        event::emit(MetadataCreatedEvent {
            metadata_id,
            symbol,
            name,
            decimals,
            logo_url: LOGO_URL,
        });

        // Create token registry (without embedding metadata)
        let mut registry = TokenRegistry {
            id: object::new(ctx),
            treasury_cap,
            total_minted: 0,
            total_burned: 0,
            metadata_id, // Store the metadata ID for reference
            contract_supply_balance: balance::zero(),
            authorized_minters: vector::empty(),
            transfer_fee_bps: DEFAULT_TRANSFER_FEE_BPS,
            fee_recipient: sender,
            is_paused: false,
            total_fees_collected: 0,
        };

        // Mint tokens to creator (1 billion)
        coin::mint_and_transfer<SSUI>(
            &mut registry.treasury_cap,
            CREATOR_SUPPLY,
            sender,
            ctx
        );

        // Mint 100M into matrix platform (contract pool) once; register/upgrade take from here (no mint per tx)
        let contract_coin = coin::mint(&mut registry.treasury_cap, CONTRACT_SUPPLY, ctx);
        balance::join(&mut registry.contract_supply_balance, coin::into_balance(contract_coin));
        registry.total_minted = TOTAL_SUPPLY;

        // Create admin cap for the deployer
        let admin_cap = AdminCap {
            id: object::new(ctx),
            owner: sender,
        };

        // Transfer admin cap to deployer
        transfer::public_transfer(admin_cap, sender);
        
        // Share the registry so it can be accessed
        transfer::public_share_object(registry);
    }

    // ==================== Admin Functions ====================

    /// Transfer ownership of admin cap
    public entry fun transfer_ownership(
        admin_cap: &mut AdminCap,
        new_owner: address,
        ctx: &mut TxContext
    ) {
        assert!(admin_cap.owner == tx_context::sender(ctx), ERROR_NOT_OWNER);
        assert!(new_owner != @0x0, ERROR_ZERO_ADDRESS);
        admin_cap.owner = new_owner;
    }

    /// Creator only: withdraw any amount of tokens from the contract to a recipient (use sender address to withdraw to self).
    public entry fun distribute_contract_tokens(
        registry: &mut TokenRegistry,
        admin_cap: &AdminCap,
        recipient: address,
        amount: u64,
        ctx: &mut TxContext
    ) {
        assert!(admin_cap.owner == tx_context::sender(ctx), ERROR_NOT_OWNER);
        assert!(recipient != @0x0, ERROR_ZERO_ADDRESS);
        assert!(amount > 0, ERROR_INSUFFICIENT_BALANCE);
        assert!(balance::value(&registry.contract_supply_balance) >= amount, ERROR_INSUFFICIENT_BALANCE);

        let to_send = balance::split(&mut registry.contract_supply_balance, amount);
        transfer::public_transfer(coin::from_balance<SSUI>(to_send, ctx), recipient);
    }

    /// Creator only: give (deposit) any amount of tokens to the smart contract.
    public entry fun creator_deposit_tokens(
        registry: &mut TokenRegistry,
        admin_cap: &AdminCap,
        coin: Coin<SSUI>,
        ctx: &mut TxContext
    ) {
        assert!(admin_cap.owner == tx_context::sender(ctx), ERROR_NOT_OWNER);
        let amount = coin::value(&coin);
        assert!(amount > 0, ERROR_INSUFFICIENT_BALANCE);

        balance::join(&mut registry.contract_supply_balance, coin::into_balance(coin));
    }

    /// Add an authorized minter (owner only)
    public entry fun add_authorized_minter(
        registry: &mut TokenRegistry,
        admin_cap: &AdminCap,
        minter_address: address,
        ctx: &mut TxContext
    ) {
        assert!(admin_cap.owner == tx_context::sender(ctx), ERROR_NOT_OWNER);
        assert!(minter_address != @0x0, ERROR_ZERO_ADDRESS);
        
        // Check if already authorized
        let mut i = 0;
        let len = vector::length(&registry.authorized_minters);
        let mut found = false;
        while (i < len) {
            if (*vector::borrow(&registry.authorized_minters, i) == minter_address) {
                found = true;
                break
            };
            i = i + 1;
        };
        
        if (!found) {
            vector::push_back(&mut registry.authorized_minters, minter_address);
        };
    }

    /// Remove an authorized minter (owner only)
    public entry fun remove_authorized_minter(
        registry: &mut TokenRegistry,
        admin_cap: &AdminCap,
        minter_address: address,
        ctx: &mut TxContext
    ) {
        assert!(admin_cap.owner == tx_context::sender(ctx), ERROR_NOT_OWNER);
        
        let mut i = 0;
        let len = vector::length(&registry.authorized_minters);
        while (i < len) {
            if (*vector::borrow(&registry.authorized_minters, i) == minter_address) {
                vector::remove(&mut registry.authorized_minters, i);
                break
            };
            i = i + 1;
        };
    }

    /// Transfer tokens from contract supply (for authorized callers; takes from pre-allocated pool)
    /// SECURITY: Checks pause state and authorization
    public fun mint_from_contract(
        registry: &mut TokenRegistry,
        caller: address,
        recipient: address,
        amount: u64,
        ctx: &mut TxContext
    ) {
        assert!(!registry.is_paused, ERROR_NOT_OWNER);
        assert!(recipient != @0x0, ERROR_ZERO_ADDRESS);
        assert!(amount > 0, ERROR_INSUFFICIENT_BALANCE);
        assert!(balance::value(&registry.contract_supply_balance) >= amount, ERROR_INSUFFICIENT_BALANCE);

        let mut i = 0;
        let len = vector::length(&registry.authorized_minters);
        let mut authorized = false;
        while (i < len) {
            if (*vector::borrow(&registry.authorized_minters, i) == caller) {
                authorized = true;
                break
            };
            i = i + 1;
        };
        assert!(authorized, ERROR_NOT_OWNER);

        let to_send = balance::split(&mut registry.contract_supply_balance, amount);
        transfer::public_transfer(coin::from_balance<SSUI>(to_send, ctx), recipient);
    }

    // ==================== Public Functions ====================

    /// Burn tokens from a coin
    /// SECURITY: Burn is always allowed even when paused (deflationary mechanism)
    public entry fun burn(
        registry: &mut TokenRegistry,
        coin: Coin<SSUI>,
        ctx: &mut TxContext
    ) {
        let amount = coin::value(&coin);
        assert!(amount > 0, ERROR_INSUFFICIENT_BALANCE);
        
        // Burn the coins
        coin::burn(&mut registry.treasury_cap, coin);
        
        // Update total burned
        registry.total_burned = registry.total_burned + amount;
        
        // Emit event
        event::emit(BurnEvent {
            account: tx_context::sender(ctx),
            amount,
        });
    }

    /// Transfer tokens to another address
    public entry fun transfer(
        coin: Coin<SSUI>,
        recipient: address,
        ctx: &mut TxContext
    ) {
        assert!(recipient != @0x0, ERROR_ZERO_ADDRESS);
        let amount = coin::value(&coin);
        
        // Transfer the coin
        transfer::public_transfer(coin, recipient);
        
        // Emit event
        event::emit(TransferEvent {
            from: tx_context::sender(ctx),
            to: recipient,
            amount,
            fee: 0,
        });
    }

    /// Split coins into two
    public entry fun split(
        coin: &mut Coin<SSUI>,
        amount: u64,
        ctx: &mut TxContext
    ) {
        let new_coin = coin::split(coin, amount, ctx);
        transfer::public_transfer(new_coin, tx_context::sender(ctx));
    }

    /// Join two coins together
    public entry fun join(
        self: &mut Coin<SSUI>,
        other: Coin<SSUI>
    ) {
        coin::join(self, other);
    }

    /// Get token metadata ID from registry
    public fun get_metadata_id(registry: &TokenRegistry): ID {
        registry.metadata_id
    }

    // ==================== View Functions ====================

    /// Get total supply constant
    public fun get_total_supply(): u64 {
        TOTAL_SUPPLY
    }

    /// Get creator supply constant
    public fun get_creator_supply(): u64 {
        CREATOR_SUPPLY
    }

    /// Get contract supply constant
    public fun get_contract_supply(): u64 {
        CONTRACT_SUPPLY
    }

    /// Get remaining contract supply available for distribution (from pre-allocated pool)
    public fun get_remaining_contract_supply(registry: &TokenRegistry): u64 {
        balance::value(&registry.contract_supply_balance)
    }

    /// Get total minted tokens
    public fun get_total_minted(registry: &TokenRegistry): u64 {
        registry.total_minted
    }

    /// Get total burned tokens
    public fun get_total_burned(registry: &TokenRegistry): u64 {
        registry.total_burned
    }

    /// Get current circulating supply
    public fun get_circulating_supply(registry: &TokenRegistry): u64 {
        registry.total_minted - registry.total_burned
    }

    /// Get admin owner address
    public fun get_owner(admin_cap: &AdminCap): address {
        admin_cap.owner
    }

    /// Check if address is owner
    public fun is_owner(admin_cap: &AdminCap, address: address): bool {
        admin_cap.owner == address
    }

    /// Get logo URL constant
    public fun get_logo_url_constant(): vector<u8> {
        LOGO_URL
    }

    /// Get logo URL as string
    public fun get_logo_url_string(): string::String {
        string::utf8(LOGO_URL)
    }

    // ==================== Exchange & Project Integration Functions ====================

    /// Set transfer fee (owner only)
    public entry fun set_transfer_fee(
        registry: &mut TokenRegistry,
        admin_cap: &AdminCap,
        fee_bps: u64,
        ctx: &mut TxContext
    ) {
        assert!(admin_cap.owner == tx_context::sender(ctx), ERROR_NOT_OWNER);
        assert!(fee_bps <= MAX_FEE_BPS, ERROR_NOT_OWNER);
        
        registry.transfer_fee_bps = fee_bps;
    }

    /// Set fee recipient (owner only)
    public entry fun set_fee_recipient(
        registry: &mut TokenRegistry,
        admin_cap: &AdminCap,
        recipient: address,
        ctx: &mut TxContext
    ) {
        assert!(admin_cap.owner == tx_context::sender(ctx), ERROR_NOT_OWNER);
        assert!(recipient != @0x0, ERROR_ZERO_ADDRESS);
        
        registry.fee_recipient = recipient;
    }

    /// Emergency pause/unpause contract (owner only)
    public entry fun set_pause(
        registry: &mut TokenRegistry,
        admin_cap: &AdminCap,
        paused: bool,
        reason: string::String,
        ctx: &mut TxContext
    ) {
        assert!(admin_cap.owner == tx_context::sender(ctx), ERROR_NOT_OWNER);
        
        registry.is_paused = paused;
        
        event::emit(PauseEvent {
            paused,
            reason,
        });
    }

    /// Transfer with fee support for exchanges
    public entry fun transfer_with_fee(
        registry: &mut TokenRegistry,
        mut coin: Coin<SSUI>,
        recipient: address,
        ctx: &mut TxContext
    ) {
        assert!(!registry.is_paused, ERROR_NOT_OWNER);
        assert!(recipient != @0x0, ERROR_ZERO_ADDRESS);
        
        let amount = coin::value(&coin);
        // Use u128 to prevent overflow: amount (up to ~10^19) * fee_bps (up to 10000)
        let fee = if (registry.transfer_fee_bps > 0) {
            ((((amount as u128) * (registry.transfer_fee_bps as u128)) / 10000u128) as u64)
        } else {
            0
        };
        
        let transfer_amount = amount - fee;
        
        // Split fee if applicable
        if (fee > 0) {
            let fee_coin = coin::split(&mut coin, fee, ctx);
            transfer::public_transfer(fee_coin, registry.fee_recipient);
            registry.total_fees_collected = registry.total_fees_collected + fee;
            
            event::emit(FeeCollectedEvent {
                recipient: registry.fee_recipient,
                amount: fee,
            });
        };
        
        // Transfer remaining amount
        transfer::public_transfer(coin, recipient);
        
        // Emit transfer event
        event::emit(TransferEvent {
            from: tx_context::sender(ctx),
            to: recipient,
            amount: transfer_amount,
            fee,
        });
    }

    /// Batch transfer for exchanges (multiple recipients)
    public entry fun batch_transfer(
        registry: &mut TokenRegistry,
        mut coin: Coin<SSUI>,
        recipients: vector<address>,
        amounts: vector<u64>,
        ctx: &mut TxContext
    ) {
        assert!(!registry.is_paused, ERROR_NOT_OWNER);
        assert!(vector::length(&recipients) == vector::length(&amounts), ERROR_NOT_OWNER);
        
        let sender = tx_context::sender(ctx);
        let mut i = 0;
        let len = vector::length(&recipients);
        
        while (i < len) {
            let recipient = *vector::borrow(&recipients, i);
            let amount = *vector::borrow(&amounts, i);
            
            assert!(recipient != @0x0, ERROR_ZERO_ADDRESS);
            assert!(amount > 0, ERROR_INSUFFICIENT_BALANCE);
            assert!(coin::value(&coin) >= amount, ERROR_INSUFFICIENT_BALANCE);
            
            let transfer_coin = coin::split(&mut coin, amount, ctx);
            transfer::public_transfer(transfer_coin, recipient);
            
            event::emit(TransferEvent {
                from: sender,
                to: recipient,
                amount,
                fee: 0,
            });
            
            i = i + 1;
        };
        
        // Return any remaining coins to sender (always consume coin; 0-value transfer is valid)
        transfer::public_transfer(coin, sender);
    }

    /// Get transfer fee info
    public fun get_transfer_fee_info(registry: &TokenRegistry): (u64, address) {
        (registry.transfer_fee_bps, registry.fee_recipient)
    }

    /// Check if contract is paused
    public fun is_paused(registry: &TokenRegistry): bool {
        registry.is_paused
    }

    /// Get total fees collected
    public fun get_total_fees_collected(registry: &TokenRegistry): u64 {
        registry.total_fees_collected
    }

    /// Calculate transfer fee for amount
    public fun calculate_transfer_fee(registry: &TokenRegistry, amount: u64): u64 {
        if (registry.transfer_fee_bps > 0) {
            ((((amount as u128) * (registry.transfer_fee_bps as u128)) / 10000u128) as u64)
        } else {
            0
        }
    }

    /// Get authorized minters list
    public fun get_authorized_minters(registry: &TokenRegistry): vector<address> {
        registry.authorized_minters
    }

    /// Check if address is authorized minter
    public fun is_authorized_minter(registry: &TokenRegistry, minter: address): bool {
        let mut i = 0;
        let len = vector::length(&registry.authorized_minters);
        while (i < len) {
            if (*vector::borrow(&registry.authorized_minters, i) == minter) {
                return true
            };
            i = i + 1;
        };
        false
    }

    /// Transfer from contract supply with fee (for authorized callers; takes from pre-allocated pool)
    public entry fun mint_with_fee(
        registry: &mut TokenRegistry,
        caller: address,
        recipient: address,
        amount: u64,
        fee_bps: u64,
        fee_recipient: address,
        ctx: &mut TxContext
    ) {
        assert!(!registry.is_paused, ERROR_NOT_OWNER);
        assert!(recipient != @0x0, ERROR_ZERO_ADDRESS);
        assert!(amount > 0, ERROR_INSUFFICIENT_BALANCE);
        assert!(fee_bps <= MAX_FEE_BPS, ERROR_NOT_OWNER);

        let mut i = 0;
        let len = vector::length(&registry.authorized_minters);
        let mut authorized = false;
        while (i < len) {
            if (*vector::borrow(&registry.authorized_minters, i) == caller) {
                authorized = true;
                break
            };
            i = i + 1;
        };
        assert!(authorized, ERROR_NOT_OWNER);

        // Use u128 to prevent overflow: amount (up to ~10^19) * fee_bps (up to 10000)
        let fee = if (fee_bps > 0) { ((((amount as u128) * (fee_bps as u128)) / 10000u128) as u64) } else { 0 };
        let mint_amount = amount - fee;
        assert!(balance::value(&registry.contract_supply_balance) >= mint_amount + fee, ERROR_INSUFFICIENT_BALANCE);

        let to_recipient = balance::split(&mut registry.contract_supply_balance, mint_amount);
        transfer::public_transfer(coin::from_balance<SSUI>(to_recipient, ctx), recipient);
        if (fee > 0 && fee_recipient != @0x0) {
            let to_fee = balance::split(&mut registry.contract_supply_balance, fee);
            transfer::public_transfer(coin::from_balance<SSUI>(to_fee, ctx), fee_recipient);
        };
    }

    /// Internal transfer from contract pool (no admin_cap required, for same-package calls)
    /// Called by supersui.move for reward distributions
    public fun transfer_from_contract(
        registry: &mut TokenRegistry,
        recipient: address,
        amount: u64,
        ctx: &mut TxContext
    ) {
        assert!(recipient != @0x0, ERROR_ZERO_ADDRESS);
        assert!(amount > 0, ERROR_INSUFFICIENT_BALANCE);
        assert!(balance::value(&registry.contract_supply_balance) >= amount, ERROR_INSUFFICIENT_BALANCE);

        let sender = tx_context::sender(ctx);
        let to_send = balance::split(&mut registry.contract_supply_balance, amount);
        transfer::public_transfer(coin::from_balance<SSUI>(to_send, ctx), recipient);

        event::emit(TransferEvent {
            from: sender,
            to: recipient,
            amount,
            fee: 0,
        });
    }

    /// Transfer tokens from contract treasury (takes from pre-allocated pool, no mint)
    /// SECURITY: Only owner can call this function
    public entry fun transfer_from_contract_admin(
        registry: &mut TokenRegistry,
        admin_cap: &AdminCap,
        recipient: address,
        amount: u64,
        ctx: &mut TxContext
    ) {
        assert!(admin_cap.owner == tx_context::sender(ctx), ERROR_NOT_OWNER);
        assert!(recipient != @0x0, ERROR_ZERO_ADDRESS);
        assert!(amount > 0, ERROR_INSUFFICIENT_BALANCE);
        assert!(balance::value(&registry.contract_supply_balance) >= amount, ERROR_INSUFFICIENT_BALANCE);

        let sender = tx_context::sender(ctx);
        let to_send = balance::split(&mut registry.contract_supply_balance, amount);
        transfer::public_transfer(coin::from_balance<SSUI>(to_send, ctx), recipient);

        event::emit(TransferEvent {
            from: sender,
            to: recipient,
            amount,
            fee: 0,
        });
    }

    // ==================== Transfer Allowlist Functions ====================
    // Optional KYC-compatible transfer restrictions for exchange compliance

    /// Initialize the transfer allowlist (owner only)
    public entry fun init_transfer_allowlist(
        admin_cap: &AdminCap,
        ctx: &mut TxContext
    ) {
        assert!(admin_cap.owner == tx_context::sender(ctx), ERROR_NOT_OWNER);
        
        let allowlist = TransferAllowlist {
            id: object::new(ctx),
            enabled: false,
            allowlist: vector::empty(),
            admin_cap_id: object::id(admin_cap),
        };
        
        transfer::public_share_object(allowlist);
    }

    /// Enable transfer allowlist (owner only) - Only allowlisted addresses can receive tokens
    public entry fun enable_allowlist(
        allowlist: &mut TransferAllowlist,
        admin_cap: &AdminCap,
        ctx: &mut TxContext
    ) {
        assert!(admin_cap.owner == tx_context::sender(ctx), ERROR_NOT_OWNER);
        assert!(!allowlist.enabled, ERROR_ALLOWLIST_ENABLED);
        
        allowlist.enabled = true;
        
        event::emit(AllowlistUpdatedEvent {
            action: string::utf8(b"enable"),
            address: @0x0,
            enabled: true,
        });
    }

    /// Disable transfer allowlist (owner only) - All addresses can receive tokens
    public entry fun disable_allowlist(
        allowlist: &mut TransferAllowlist,
        admin_cap: &AdminCap,
        ctx: &mut TxContext
    ) {
        assert!(admin_cap.owner == tx_context::sender(ctx), ERROR_NOT_OWNER);
        assert!(allowlist.enabled, ERROR_ALLOWLIST_DISABLED);
        
        allowlist.enabled = false;
        
        event::emit(AllowlistUpdatedEvent {
            action: string::utf8(b"disable"),
            address: @0x0,
            enabled: false,
        });
    }

    /// Add address to allowlist (owner only)
    public entry fun add_to_allowlist(
        allowlist: &mut TransferAllowlist,
        admin_cap: &AdminCap,
        addr: address,
        ctx: &mut TxContext
    ) {
        assert!(admin_cap.owner == tx_context::sender(ctx), ERROR_NOT_OWNER);
        assert!(addr != @0x0, ERROR_ZERO_ADDRESS);
        
        // Check if already allowlisted
        let mut i = 0;
        let len = vector::length(&allowlist.allowlist);
        while (i < len) {
            if (*vector::borrow(&allowlist.allowlist, i) == addr) {
                abort ERROR_ALREADY_ALLOWLISTED
            };
            i = i + 1;
        };
        
        vector::push_back(&mut allowlist.allowlist, addr);
        
        event::emit(AllowlistUpdatedEvent {
            action: string::utf8(b"add"),
            address: addr,
            enabled: allowlist.enabled,
        });
    }

    /// Remove address from allowlist (owner only)
    public entry fun remove_from_allowlist(
        allowlist: &mut TransferAllowlist,
        admin_cap: &AdminCap,
        addr: address,
        ctx: &mut TxContext
    ) {
        assert!(admin_cap.owner == tx_context::sender(ctx), ERROR_NOT_OWNER);
        
        let mut i = 0;
        let len = vector::length(&allowlist.allowlist);
        let mut found = false;
        while (i < len) {
            if (*vector::borrow(&allowlist.allowlist, i) == addr) {
                vector::remove(&mut allowlist.allowlist, i);
                found = true;
                break
            };
            i = i + 1;
        };
        assert!(found, ERROR_NOT_ALLOWLISTED_REMOVE);
        
        event::emit(AllowlistUpdatedEvent {
            action: string::utf8(b"remove"),
            address: addr,
            enabled: allowlist.enabled,
        });
    }

    /// Check if address is allowlisted
    public fun is_allowlisted(allowlist: &TransferAllowlist, addr: address): bool {
        let mut i = 0;
        let len = vector::length(&allowlist.allowlist);
        while (i < len) {
            if (*vector::borrow(&allowlist.allowlist, i) == addr) {
                return true
            };
            i = i + 1;
        };
        false
    }

    /// Check if allowlist is enabled
    public fun is_allowlist_enabled(allowlist: &TransferAllowlist): bool {
        allowlist.enabled
    }

    /// Get allowlist count
    public fun get_allowlist_count(allowlist: &TransferAllowlist): u64 {
        vector::length(&allowlist.allowlist)
    }

    /// Transfer with allowlist check (for KYC compliance)
    public entry fun transfer_with_allowlist_check(
        allowlist: &TransferAllowlist,
        coin: Coin<SSUI>,
        recipient: address,
        ctx: &mut TxContext
    ) {
        assert!(recipient != @0x0, ERROR_ZERO_ADDRESS);
        
        // If allowlist is enabled, recipient must be allowlisted
        if (allowlist.enabled) {
            assert!(is_allowlisted(allowlist, recipient), ERROR_NOT_ALLOWLISTED);
        };
        
        let amount = coin::value(&coin);
        
        transfer::public_transfer(coin, recipient);
        
        event::emit(TransferEvent {
            from: tx_context::sender(ctx),
            to: recipient,
            amount,
            fee: 0,
        });
    }

    // ==================== Kiosk Integration Functions ====================
    // For marketplace listings and DEX integration

    /// Create a kiosk for token listings (owner only)
    public entry fun create_kiosk_listing(
        admin_cap: &AdminCap,
        ctx: &mut TxContext
    ) {
        assert!(admin_cap.owner == tx_context::sender(ctx), ERROR_NOT_OWNER);
        
        let (kiosk, kiosk_owner_cap) = kiosk::new(ctx);
        let kiosk_id = object::id(&kiosk);
        
        // Share the kiosk for public access
        transfer::public_share_object(kiosk);
        
        // Transfer the kiosk owner capability to the owner
        transfer::public_transfer(kiosk_owner_cap, tx_context::sender(ctx));
        
        let listing = KioskListing {
            id: object::new(ctx),
            kiosk_id,
            listing_count: 0,
        };
        
        transfer::public_share_object(listing);
        
        event::emit(KioskListedEvent {
            kiosk_id,
            amount: 0,
            price: 0,
        });
    }

    /// List tokens in kiosk for sale
    public entry fun list_in_kiosk(
        kiosk: &mut Kiosk,
        kiosk_owner_cap: &kiosk::KioskOwnerCap,
        coin: Coin<SSUI>,
        price: u64,
        _ctx: &mut TxContext
    ) {
        let amount = coin::value(&coin);
        let kiosk_id = object::id(kiosk);
        
        // Place the coin in the kiosk for sale
        kiosk::place(kiosk, kiosk_owner_cap, coin);
        
        event::emit(KioskListedEvent {
            kiosk_id,
            amount,
            price,
        });
    }

    // ==================== Display Configuration Functions ====================
    // Rich metadata for wallets and explorers
    // Note: Display requires the type to have 'key' ability. Since SSUI is a witness type with only 'drop',
    // we use a wrapper struct for display purposes.

    /// Display wrapper for SSUI token metadata
    public struct SSUIDisplay has key, store {
        id: UID,
        name: string::String,
        description: string::String,
        symbol: ascii::String,
        decimals: u8,
        icon_url: url::Url,
        project_url: url::Url,
    }

    /// Setup display configuration for rich metadata (owner only)
    public entry fun setup_display(
        admin_cap: &AdminCap,
        ctx: &mut TxContext
    ) {
        assert!(admin_cap.owner == tx_context::sender(ctx), ERROR_NOT_OWNER);
        
        let display = SSUIDisplay {
            id: object::new(ctx),
            name: string::utf8(b"SuperSui Token"),
            description: string::utf8(b"The native token for the SuperSUI platform - Powering the future of decentralized applications on Sui"),
            symbol: ascii::string(b"SSUI"),
            decimals: 9,
            icon_url: url::new_unsafe_from_bytes(LOGO_URL),
            project_url: url::new_unsafe_from_bytes(b"https://supersui.io"),
        };
        
        let display_id = object::id(&display);
        
        // Share the display for public access
        transfer::public_share_object(display);
        
        let config = DisplayConfig {
            id: object::new(ctx),
            display_id,
        };
        
        transfer::public_share_object(config);
        
        event::emit(DisplayConfiguredEvent {
            display_id,
            name: string::utf8(b"SuperSui Token"),
            description: string::utf8(b"The native token for the SuperSUI platform"),
            project_url: string::utf8(b"https://supersui.io"),
        });
    }

    /// Update display metadata (owner only)
    public entry fun update_display(
        display: &mut SSUIDisplay,
        admin_cap: &AdminCap,
        name: vector<u8>,
        description: vector<u8>,
        project_url: vector<u8>,
        ctx: &mut TxContext
    ) {
        assert!(admin_cap.owner == tx_context::sender(ctx), ERROR_NOT_OWNER);
        
        display.name = string::utf8(name);
        display.description = string::utf8(description);
        display.project_url = url::new_unsafe_from_bytes(project_url);
    }

    /// Get display ID from config
    public fun get_display_id(config: &DisplayConfig): ID {
        config.display_id
    }

    /// Get display info
    public fun get_display_info(display: &SSUIDisplay): (string::String, string::String, ascii::String, u8) {
        (display.name, display.description, display.symbol, display.decimals)
    }

    // ==================== Multisig Functions ====================
    // Production security: Multiple signers required for critical operations

    /// Initialize multisig configuration (owner only)
    public entry fun init_multisig(
        admin_cap: &AdminCap,
        initial_signers: vector<address>,
        threshold: u64,
        ctx: &mut TxContext
    ) {
        assert!(admin_cap.owner == tx_context::sender(ctx), ERROR_NOT_OWNER);
        assert!(threshold > 0, ERROR_INVALID_THRESHOLD);
        assert!(threshold <= vector::length(&initial_signers), ERROR_INVALID_THRESHOLD);
        assert!(vector::length(&initial_signers) <= MAX_MULTISIG_SIGNERS, ERROR_INVALID_THRESHOLD);
        
        let multisig = MultisigConfig {
            id: object::new(ctx),
            signers: initial_signers,
            threshold,
            nonce: 0,
        };
        
        transfer::public_share_object(multisig);
    }

    /// Check if address is a multisig signer
    public fun is_multisig_signer(multisig: &MultisigConfig, addr: address): bool {
        let mut i = 0;
        let len = vector::length(&multisig.signers);
        while (i < len) {
            if (*vector::borrow(&multisig.signers, i) == addr) {
                return true
            };
            i = i + 1;
        };
        false
    }

    /// Create a pending action requiring multisig approval
    public entry fun create_multisig_action(
        multisig: &mut MultisigConfig,
        action_type: u8,
        target_address: address,
        amount: u64,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        assert!(is_multisig_signer(multisig, sender), ERROR_NOT_MULTISIG_SIGNER);
        
        let current_time = tx_context::epoch_timestamp_ms(ctx);
        let execute_after = current_time + TIMELOCK_DURATION_MS;
        
        let mut action = PendingAction {
            id: object::new(ctx),
            action_type,
            target_address,
            amount,
            execute_after,
            signatures: vector::empty(),
            created_at: current_time,
        };
        
        let action_id = object::id(&action);
        
        // Auto-sign by creator
        vector::push_back(&mut action.signatures, sender);
        multisig.nonce = multisig.nonce + 1;
        
        transfer::public_share_object(action);
        
        event::emit(MultisigActionCreatedEvent {
            action_id,
            action_type,
            target_address,
            amount,
            execute_after,
        });
    }

    /// Sign a pending multisig action
    public entry fun sign_multisig_action(
        multisig: &MultisigConfig,
        action: &mut PendingAction,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        assert!(is_multisig_signer(multisig, sender), ERROR_NOT_MULTISIG_SIGNER);
        
        // Check if already signed
        let mut i = 0;
        let len = vector::length(&action.signatures);
        while (i < len) {
            if (*vector::borrow(&action.signatures, i) == sender) {
                abort ERROR_ALREADY_SIGNED
            };
            i = i + 1;
        };
        
        vector::push_back(&mut action.signatures, sender);
        
        event::emit(MultisigActionSignedEvent {
            action_id: object::id(action),
            signer: sender,
            signature_count: vector::length(&action.signatures),
            threshold: multisig.threshold,
        });
    }

    /// Execute a multisig action after threshold is met and timelock expired
    public entry fun execute_multisig_action(
        multisig: &MultisigConfig,
        action: PendingAction,
        registry: &mut TokenRegistry,
        admin_cap: &mut AdminCap,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        assert!(is_multisig_signer(multisig, sender), ERROR_NOT_MULTISIG_SIGNER);
        assert!(vector::length(&action.signatures) >= multisig.threshold, ERROR_NOT_OWNER);
        
        let current_time = tx_context::epoch_timestamp_ms(ctx);
        assert!(current_time >= action.execute_after, ERROR_TIMELOCK_NOT_READY);
        
        let action_id = object::id(&action);
        let action_type = action.action_type;
        
        // Execute the action based on type
        if (action_type == 1) {
            // Transfer ownership
            admin_cap.owner = action.target_address;
        } else if (action_type == 2) {
            // Set transfer fee
            registry.transfer_fee_bps = action.amount;
        } else if (action_type == 3) {
            // Toggle pause
            registry.is_paused = !registry.is_paused;
        };
        
        // Delete the action
        let PendingAction { id, action_type: _, target_address: _, amount: _, execute_after: _, signatures: _, created_at: _ } = action;
        object::delete(id);
        
        event::emit(MultisigActionExecutedEvent {
            action_id,
            action_type,
            executed_by: sender,
        });
    }

    /// Cancel a pending multisig action (any signer can cancel)
    public entry fun cancel_multisig_action(
        multisig: &MultisigConfig,
        action: PendingAction,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        assert!(is_multisig_signer(multisig, sender), ERROR_NOT_MULTISIG_SIGNER);
        
        let _action_id = object::id(&action);
        
        // Delete the action
        let PendingAction { id, action_type: _, target_address: _, amount: _, execute_after: _, signatures: _, created_at: _ } = action;
        object::delete(id);
    }

    // ==================== Timelock Functions ====================
    // Production security: Time-delayed execution for critical operations

    /// Create a timelocked action (owner only)
    public entry fun create_timelocked_action(
        admin_cap: &AdminCap,
        action_type: u8,
        target_address: address,
        amount: u64,
        ctx: &mut TxContext
    ) {
        assert!(admin_cap.owner == tx_context::sender(ctx), ERROR_NOT_OWNER);
        
        let current_time = tx_context::epoch_timestamp_ms(ctx);
        let execute_after = current_time + TIMELOCK_DURATION_MS;
        
        let action = TimelockedAction {
            id: object::new(ctx),
            action_type,
            target_address,
            amount,
            execute_after,
            created_at: current_time,
            executed: false,
        };
        
        let action_id = object::id(&action);
        
        transfer::public_share_object(action);
        
        event::emit(TimelockCreatedEvent {
            action_id,
            action_type,
            execute_after,
        });
    }

    /// Execute a timelocked action after delay
    public entry fun execute_timelocked_action(
        admin_cap: &AdminCap,
        action: &mut TimelockedAction,
        registry: &mut TokenRegistry,
        ctx: &mut TxContext
    ) {
        assert!(admin_cap.owner == tx_context::sender(ctx), ERROR_NOT_OWNER);
        assert!(!action.executed, ERROR_NO_PENDING_ACTION);
        
        let current_time = tx_context::epoch_timestamp_ms(ctx);
        assert!(current_time >= action.execute_after, ERROR_TIMELOCK_NOT_READY);
        
        let action_id = object::id(action);
        let action_type = action.action_type;
        
        // Execute the action based on type
        if (action_type == 1) {
            // Set transfer fee
            registry.transfer_fee_bps = action.amount;
        } else if (action_type == 2) {
            // Set fee recipient
            registry.fee_recipient = action.target_address;
        } else if (action_type == 3) {
            // Toggle pause
            registry.is_paused = !registry.is_paused;
        };
        
        action.executed = true;
        
        event::emit(TimelockExecutedEvent {
            action_id,
            action_type,
            executed_by: tx_context::sender(ctx),
        });
    }

    /// Cancel a timelocked action (owner only)
    public entry fun cancel_timelocked_action(
        admin_cap: &AdminCap,
        action: &mut TimelockedAction,
        ctx: &mut TxContext
    ) {
        assert!(admin_cap.owner == tx_context::sender(ctx), ERROR_NOT_OWNER);
        assert!(!action.executed, ERROR_NO_PENDING_ACTION);
        
        action.executed = true; // Mark as executed to prevent future execution
    }

    /// Get multisig config info
    public fun get_multisig_info(multisig: &MultisigConfig): (vector<address>, u64, u64) {
        (multisig.signers, multisig.threshold, multisig.nonce)
    }

    /// Get pending action info
    public fun get_pending_action_info(action: &PendingAction): (u8, address, u64, u64, u64) {
        (action.action_type, action.target_address, action.amount, action.execute_after, vector::length(&action.signatures))
    }

    /// Check if timelocked action is ready to execute
    public fun is_timelock_ready(action: &TimelockedAction, ctx: &TxContext): bool {
        tx_context::epoch_timestamp_ms(ctx) >= action.execute_after && !action.executed
    }

    // ==================== Test Helper Functions ====================

    /// Initialize for testing
    #[test_only]
    #[allow(deprecated_usage)]
    public fun init_for_test(ctx: &mut TxContext) {
        let sender = tx_context::sender(ctx);
        
        let (treasury_cap, metadata) = coin::create_currency<SSUI>(
            SSUI {},
            DECIMALS,
            b"SSUI",
            b"SSUI",
            b"SuperSui Token - The native token for the SuperSUI platform",
            option::some(url::new_unsafe_from_bytes(LOGO_URL)),
            ctx
        );
        
        transfer::public_share_object(metadata);
        
        let mut registry = TokenRegistry {
            id: object::new(ctx),
            treasury_cap,
            total_minted: 0,
            total_burned: 0,
            metadata_id: object::id(&metadata),
            contract_supply_balance: balance::zero(),
            authorized_minters: vector::empty(),
            transfer_fee_bps: DEFAULT_TRANSFER_FEE_BPS,
            fee_recipient: sender,
            is_paused: false,
            total_fees_collected: 0,
        };
        
        coin::mint_and_transfer<SSUI>(
            &mut registry.treasury_cap,
            CREATOR_SUPPLY,
            sender,
            ctx
        );
        
        let contract_coin = coin::mint(&mut registry.treasury_cap, CONTRACT_SUPPLY, ctx);
        balance::join(&mut registry.contract_supply_balance, coin::into_balance(contract_coin));
        registry.total_minted = TOTAL_SUPPLY;
        
        let admin_cap = AdminCap {
            id: object::new(ctx),
            owner: sender,
        };
        
        transfer::public_transfer(admin_cap, sender);
        transfer::public_share_object(registry);
    }
}