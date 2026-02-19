#[allow(duplicate_alias, lint(public_entry))]
module ssui::ssui {
    use sui::balance;
    use sui::coin::{Self, Coin, TreasuryCap};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::event;
    use sui::object::{Self, UID, ID};
    use sui::url;
    use std::option;
    use std::string;
    use std::ascii;
    use std::vector;
    
    // ==================== Error Codes ====================
    const ERROR_NOT_OWNER: u64 = 1;
    const ERROR_INSUFFICIENT_BALANCE: u64 = 2;
    const ERROR_ZERO_ADDRESS: u64 = 3;
    
    // ==================== Constants ====================
    // 9 decimals: 1 SSUI = 1_000_000_000 raw units (like SUI/MIST). Total 10.1B SSUI.
    const DECIMALS: u8 = 9;
    const TOTAL_SUPPLY: u64 = 10_100_000_000_000_000_000; // 10.1 billion SSUI (with 9 decimals)
    const CREATOR_SUPPLY: u64 = 10_000_000_000_000_000_000; // 10 billion SSUI to creator
    const CONTRACT_SUPPLY: u64 = 100_000_000_000_000_000; // 100 million SSUI for contract pool
    const LOGO_URL: vector<u8> = b"https://i.postimg.cc/1X6mTW3h/ssui.png";
    
    // Exchange and project integration constants
    const MAX_FEE_BPS: u64 = 10000; // 100% in basis points
    const DEFAULT_TRANSFER_FEE_BPS: u64 = 0; // 0% default transfer fee

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
        contract_supply_balance: balance::Balance<SSUI>, // Pre-allocated 1B tokens for distribution (no mint on register/upgrade)
        authorized_minters: vector<address>, // Addresses authorized to take from contract supply
        transfer_fee_bps: u64, // Transfer fee in basis points (0.01% = 1 bps)
        fee_recipient: address, // Address to receive transfer fees
        is_paused: bool, // Emergency pause functionality
        total_fees_collected: u64, // Track total fees collected
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

        // Mint tokens to creator (10 billion)
        coin::mint_and_transfer<SSUI>(
            &mut registry.treasury_cap,
            CREATOR_SUPPLY,
            sender,
            ctx
        );

        // Mint 1 billion into contract pool once; register/upgrade take from here (no mint per tx)
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
    public fun mint_from_contract(
        registry: &mut TokenRegistry,
        caller: address,
        recipient: address,
        amount: u64,
        ctx: &mut TxContext
    ) {
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

    /// Transfer tokens from contract treasury (takes from pre-allocated 1B pool, no mint)
    public entry fun transfer_from_contract(
        registry: &mut TokenRegistry,
        recipient: address,
        amount: u64,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        assert!(amount > 0, ERROR_INSUFFICIENT_BALANCE);
        assert!(balance::value(&registry.contract_supply_balance) >= amount, ERROR_INSUFFICIENT_BALANCE);

        let to_send = balance::split(&mut registry.contract_supply_balance, amount);
        transfer::public_transfer(coin::from_balance<SSUI>(to_send, ctx), recipient);

        event::emit(TransferEvent {
            from: sender,
            to: recipient,
            amount,
            fee: 0,
        });
    }
}