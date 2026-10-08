// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Minimal, ABI-compatible Uniswap v4 types. No external source dependencies are required.
type Currency is address;
type BalanceDelta is int256;
type BeforeSwapDelta is int256;

struct PoolKey {
    Currency currency0;
    Currency currency1;
    uint24 fee;
    int24 tickSpacing;
    IHooks hooks;
}

struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

library Hooks {
    struct Permissions {
        bool beforeInitialize;
        bool afterInitialize;
        bool beforeAddLiquidity;
        bool afterAddLiquidity;
        bool beforeRemoveLiquidity;
        bool afterRemoveLiquidity;
        bool beforeSwap;
        bool afterSwap;
        bool beforeDonate;
        bool afterDonate;
        bool beforeSwapReturnDelta;
        bool afterSwapReturnDelta;
        bool afterAddLiquidityReturnDelta;
        bool afterRemoveLiquidityReturnDelta;
    }
}

interface IHooks {
    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96) external returns (bytes4);
    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata data)
        external
        returns (bytes4, BeforeSwapDelta, uint24);
    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata data
    ) external returns (bytes4, int128);
}

interface IPoolManager {
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey calldata key, SwapParams calldata params, bytes calldata data) external returns (BalanceDelta);
    function donate(PoolKey calldata key, uint256 amount0, uint256 amount1, bytes calldata data)
        external
        returns (BalanceDelta);
    function take(Currency currency, address to, uint256 amount) external;
    function mint(address to, uint256 id, uint256 amount) external;
    function burn(address from, uint256 id, uint256 amount) external;
    function sync(Currency currency) external;
    function settle() external payable returns (uint256);
    function extsload(bytes32 slot) external view returns (bytes32);
}

interface IERC20Balance {
    function balanceOf(address account) external view returns (uint256);
}

/// @notice Fixed-supply launch token; the factory receives the complete supply.
/// @dev The launch factory must allocate 800,000,000 tokens to liquidity and
/// 100,000,000 to HACKATHON_RECIPIENT. Allocation is not a tax on token transfers.
contract SIMDTEST {
    string public constant name = "SIMDTEST";
    string public constant symbol = "SIMDTEST";
    uint8 public constant decimals = 18;
    uint256 public constant totalSupply = 1_000_000_000 ether;
    address public constant HACKATHON_RECIPIENT = 0x3dD5F73dD1A4E62630fAd3909673F130aD429985;
    uint256 public constant POOL_ALLOCATION = 800_000_000 ether;
    uint256 public constant HACKATHON_ALLOCATION = 100_000_000 ether;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed holder, address indexed spender, uint256 value);

    constructor() {
        balanceOf[msg.sender] = totalSupply;
        emit Transfer(address(0), msg.sender, totalSupply);
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 permitted = allowance[from][msg.sender];
        if (permitted != type(uint256).max) {
            require(permitted >= value, "Insufficient allowance");
            allowance[from][msg.sender] = permitted - value;
        }
        _transfer(from, to, value);
        return true;
    }

    function _transfer(address from, address to, uint256 value) private {
        require(to != address(0), "Zero recipient");
        require(balanceOf[from] >= value, "Insufficient balance");
        balanceOf[from] -= value;
        balanceOf[to] += value;
        emit Transfer(from, to, value);
    }
}

/// @notice Immutable, single-pool SIMDTEST/IMD fee and buyback hook.
/// @dev Deploy with CREATE2 so the low 14 address bits equal HOOK_FLAGS.
/// IMD is supplied as pairedCurrency_; no chain-specific addresses are assumed.
/// Fees use paired-currency minor units, irrespective of its ERC20 decimals.
/// For pair-specified exact inputs, fees are included in the input budget; for
/// pair-specified exact outputs, they are added to the requested output. For
/// token-specified swaps, fees are based on the actual paired-currency pool delta.
/// The fixed launch/platform 1% fee is external to this hook. The hook neither
/// replaces it nor overrides the pool's fixed 12,500 (1.25%) LP fee.
contract SIMDTESTHook is IHooks {
    uint256 public constant BPS = 10_000;
    uint256 public constant ANTI_SNIPE_BLOCKS = 10;
    uint256 public constant INITIAL_ANTI_SNIPE_BPS = 3_000;
    uint256 public constant BUYBACK_FEE_BPS = 50;
    uint24 public constant POOL_FEE = 12_500;
    uint160 public constant HOOK_FLAGS = 0x20cc;
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    uint160 private constant MIN_SQRT_PRICE = 4295128739;
    uint160 private constant MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;

    IPoolManager public immutable poolManager;
    address public immutable pairedCurrency;
    address public immutable initializer;
    uint256 public immutable earliestOpenBlock;
    address public token;
    uint256 public poolOpenBlock;
    bytes32 public poolId;
    bool public initialized;
    // At settled transaction boundaries, paired ERC20 balance + pairedClaims
    // covers accumulatedPairedFees + pendingDonation. Neither reserve has a
    // withdrawal path; each can only fund its designated pool operation.
    uint256 public accumulatedPairedFees;
    uint256 public pendingDonation;
    /// @notice Paired-currency ERC6909 claims held by this hook at the manager.
    /// Used only when incoming swap funds have not yet been settled by the router.
    uint256 public pairedClaims;
    PoolKey private _poolKey;
    bool private _entered;
    bool private _unlockExpected;

    // A prior observed block's price bounds buybacks; never use the current
    // transaction's manipulated spot price as their reference. This is not a
    // fair-value oracle: sustained price manipulation remains an economic risk.
    uint160 public buybackReferenceSqrtPriceX96;
    uint160 private _lastSqrtPriceX96;
    uint256 private _priceBlock;

    error OnlyPoolManager();
    error InvalidConfiguration();
    error InvalidPool();
    error PoolNotOpen();
    error UnauthorizedInitialization();
    error Reentrancy();
    error InvalidAmount();
    error TransferFailed();
    error SettlementMismatch();
    error UnexpectedUnlock();
    error BuybackPriceLimit();
    error InsufficientOutput();
    error SwapQuote(int128 pairedDelta);
    error OnlySelf();

    event PoolOpened(bytes32 indexed poolId, address indexed token, uint256 openBlock);
    event FeesCollected(uint256 pairedAmount, uint256 antiSnipeDonation, uint256 buybackFee);
    event Donated(uint256 pairedAmount);
    event DonationDeferred(uint256 pairedAmount);
    event BuybackBurned(address indexed caller, uint256 pairedSpent, uint256 tokensBurned);

    /// @param openBlock_ Earliest trading block; zero opens at pool initialization.
    /// A delayed initialization starts a fresh ten-block anti-snipe period.
    constructor(IPoolManager manager_, address pairedCurrency_, uint256 openBlock_) {
        if (
            address(manager_).code.length == 0 || pairedCurrency_.code.length == 0
                || uint160(address(this)) & 0x3fff != HOOK_FLAGS
        ) revert InvalidConfiguration();
        poolManager = manager_;
        pairedCurrency = pairedCurrency_;
        initializer = msg.sender;
        earliestOpenBlock = openBlock_;
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    modifier nonReentrant() {
        if (_entered) revert Reentrancy();
        _entered = true;
        _;
        _entered = false;
    }

    function getHookPermissions() external pure returns (Hooks.Permissions memory permissions) {
        permissions.beforeInitialize = true;
        permissions.beforeSwap = true;
        permissions.afterSwap = true;
        permissions.beforeSwapReturnDelta = true;
        permissions.afterSwapReturnDelta = true;
    }

    function getPoolKey() external view returns (PoolKey memory) {
        return _poolKey;
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        external
        onlyPoolManager
        returns (bytes4)
    {
        if (sender != initializer || initialized) revert UnauthorizedInitialization();
        address currency0 = Currency.unwrap(key.currency0);
        address currency1 = Currency.unwrap(key.currency1);
        if (
            address(key.hooks) != address(this) || key.fee != POOL_FEE || key.tickSpacing <= 0 || currency0 >= currency1
                || (currency0 != pairedCurrency && currency1 != pairedCurrency)
        ) {
            revert InvalidPool();
        }
        address launchToken = currency0 == pairedCurrency ? currency1 : currency0;
        if (launchToken.code.length == 0) revert InvalidPool();
        token = launchToken;
        initialized = true;
        _poolKey = key;
        poolId = keccak256(abi.encode(key));
        poolOpenBlock = earliestOpenBlock > block.number ? earliestOpenBlock : block.number;
        buybackReferenceSqrtPriceX96 = sqrtPriceX96;
        _lastSqrtPriceX96 = sqrtPriceX96;
        _priceBlock = block.number;
        emit PoolOpened(poolId, launchToken, poolOpenBlock);
        return IHooks.beforeInitialize.selector;
    }

    /// @notice 30%, 27%, ... 3% on blocks open through open+9; zero from open+10.
    function antiSnipeFeeBps() public view returns (uint256) {
        if (!initialized || block.number < poolOpenBlock) return 0;
        uint256 elapsed = block.number - poolOpenBlock;
        return
            elapsed >= ANTI_SNIPE_BLOCKS
                ? 0
                : INITIAL_ANTI_SNIPE_BPS * (ANTI_SNIPE_BLOCKS - elapsed) / ANTI_SNIPE_BLOCKS;
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        nonReentrant
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _checkPool(key);
        _checkOpen();
        _flushDonation();
        uint256 fee = 0;
        if (_pairIsSpecified(params)) {
            (uint256 donation, uint256 buyback) = _specifiedFees(params, _previewPairedAmount(params));
            fee = donation + buyback;
        }
        // Only the executed portion's paired fee is reserved. The reverting
        // preview leaves no balances, protocol fees, events or pool state behind.
        return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(int256(fee << 128)), 0);
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        nonReentrant
        returns (bytes4, int128)
    {
        _checkPool(key);
        _checkOpen();
        int128 pairedDelta = _pairDelta(delta);
        uint256 executed = pairedDelta < 0 ? uint256(-int256(pairedDelta)) : uint256(int256(pairedDelta));
        uint256 donation;
        uint256 buyback;
        bool specified = _pairIsSpecified(params);
        if (specified) {
            (donation, buyback) = _specifiedFees(params, executed);
        } else {
            (donation, buyback) = _fees(executed);
        }
        _collect(donation, buyback);
        _recordPrice();
        emit FeesCollected(executed, donation, buyback);
        return (IHooks.afterSwap.selector, specified ? int128(0) : int128(int256(donation + buyback)));
    }

    /// @notice Permissionless redemption. Unspent paired currency remains available
    /// when the pool has insufficient liquidity inside the buyback price bound.
    /// Execution stops at a 1% adverse square-root-price move (about 2% in price)
    /// from the prior observed block's reference.
    /// v4 skips this hook's callbacks on its own swaps; buybacks do not recursively
    /// tax themselves, but still pay the unchanged pool and protocol fees.
    function buybackAndBurn() external nonReentrant returns (uint256 tokensBurned) {
        return _buybackAndBurn(1);
    }

    /// @notice Optional stronger output protection for the transaction submitter.
    function buybackAndBurn(uint256 minimumTokensOut) external nonReentrant returns (uint256 tokensBurned) {
        if (minimumTokensOut == 0) revert InvalidAmount();
        return _buybackAndBurn(minimumTokensOut);
    }

    function _buybackAndBurn(uint256 minimumTokensOut) private returns (uint256 tokensBurned) {
        _checkOpen();
        uint256 amount = accumulatedPairedFees;
        if (amount == 0) return 0;
        // Each v4 currency delta must fit int128. Larger reserves redeem in batches.
        if (amount > uint256(uint128(type(int128).max))) amount = uint256(uint128(type(int128).max));
        accumulatedPairedFees -= amount;
        _unlockExpected = true;
        (uint256 spent, uint256 burned) =
            abi.decode(poolManager.unlock(abi.encode(amount, minimumTokensOut)), (uint256, uint256));
        if (_unlockExpected) revert UnexpectedUnlock();
        emit BuybackBurned(msg.sender, spent, burned);
        return burned;
    }

    /// @dev Only a buyback initiated above can create a manager unlock callback.
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        if (!_unlockExpected) revert UnexpectedUnlock();
        _unlockExpected = false;
        (uint256 amount, uint256 minimumTokensOut) = abi.decode(data, (uint256, uint256));
        _flushDonation();
        _recordPrice();
        bool zeroForOne = Currency.unwrap(_poolKey.currency0) == pairedCurrency;
        uint256 referencePrice = buybackReferenceSqrtPriceX96;
        uint256 limit = zeroForOne ? referencePrice * 9900 / BPS : referencePrice * 10100 / BPS;
        if (limit <= MIN_SQRT_PRICE) limit = MIN_SQRT_PRICE + 1;
        if (limit >= MAX_SQRT_PRICE) limit = MAX_SQRT_PRICE - 1;
        if (zeroForOne ? _lastSqrtPriceX96 <= limit : _lastSqrtPriceX96 >= limit) revert BuybackPriceLimit();
        BalanceDelta delta = poolManager.swap(_poolKey, SwapParams(zeroForOne, -int256(amount), uint160(limit)), "");
        int128 pairDelta = _pairDelta(delta);
        int128 tokenDelta = zeroForOne ? int128(BalanceDelta.unwrap(delta)) : int128(BalanceDelta.unwrap(delta) >> 128);
        if (pairDelta >= 0 || tokenDelta <= 0) revert InsufficientOutput();
        uint256 spent = uint256(-int256(pairDelta));
        uint256 burned = uint256(int256(tokenDelta));
        if (spent > amount || burned < minimumTokensOut) revert InsufficientOutput();
        accumulatedPairedFees += amount - spent;
        _settlePaired(spent);
        // The only currency ever sent to the dead address is the launch token.
        poolManager.take(Currency.wrap(token), BURN_ADDRESS, burned);
        _recordPrice();
        return abi.encode(spent, burned);
    }

    function _collect(uint256 donation, uint256 buyback) private {
        accumulatedPairedFees += buyback;
        uint256 takeAmount = buyback;
        if (donation != 0) {
            if (_liquidity() == 0) {
                // A swap may exhaust a range. Preserve its donation separately
                // until in-range liquidity returns instead of trapping that trade.
                pendingDonation += donation;
                takeAmount += donation;
                emit DonationDeferred(donation);
            } else {
                _donate(donation);
            }
        }
        if (takeAmount != 0) {
            // Flash accounting permits the router to pay after the callbacks.
            // An exhausted manager balance must not prevent a restoring trade.
            if (IERC20Balance(pairedCurrency).balanceOf(address(poolManager)) >= takeAmount) {
                poolManager.take(Currency.wrap(pairedCurrency), address(this), takeAmount);
            } else {
                pairedClaims += takeAmount;
                poolManager.mint(address(this), uint160(pairedCurrency), takeAmount);
            }
        }
    }

    function _flushDonation() private {
        uint256 amount = pendingDonation;
        if (amount == 0 || _liquidity() == 0) return;
        if (amount > uint256(uint128(type(int128).max))) amount = uint256(uint128(type(int128).max));
        pendingDonation -= amount;
        _donate(amount);
        _settlePaired(amount);
    }

    function _donate(uint256 amount) private {
        bool pairIs0 = Currency.unwrap(_poolKey.currency0) == pairedCurrency;
        poolManager.donate(_poolKey, pairIs0 ? amount : 0, pairIs0 ? 0 : amount, "");
        emit Donated(amount);
    }

    function _settlePaired(uint256 amount) private {
        uint256 claims = pairedClaims < amount ? pairedClaims : amount;
        if (claims != 0) {
            pairedClaims -= claims;
            // Redeeming accounting claims is not burning paired ERC20 tokens.
            poolManager.burn(address(this), uint160(pairedCurrency), claims);
            amount -= claims;
        }
        if (amount == 0) return;
        poolManager.sync(Currency.wrap(pairedCurrency));
        (bool ok, bytes memory result) = pairedCurrency.call(
            abi.encodeWithSelector(bytes4(keccak256("transfer(address,uint256)")), address(poolManager), amount)
        );
        if (!ok || (result.length != 0 && (result.length < 32 || !abi.decode(result, (bool))))) {
            revert TransferFailed();
        }
        // IMD must be a non-rebasing, non-transfer-tax ERC20. Never subsidize a
        // short settlement with another user's fees or with pending donations.
        uint256 paid = poolManager.settle();
        if (paid != amount) revert SettlementMismatch();
    }

    function _recordPrice() private {
        uint160 price = uint160(uint256(poolManager.extsload(_stateSlot())));
        if (block.number > _priceBlock) {
            buybackReferenceSqrtPriceX96 = _lastSqrtPriceX96;
            _priceBlock = block.number;
        }
        _lastSqrtPriceX96 = price;
    }

    function _stateSlot() private view returns (bytes32) {
        // Uniswap v4 PoolManager.pools mapping is at storage slot 6.
        return keccak256(abi.encode(poolId, uint256(6)));
    }

    function _liquidity() private view returns (uint128) {
        return uint128(uint256(poolManager.extsload(bytes32(uint256(_stateSlot()) + 3))));
    }

    function _pairDelta(BalanceDelta delta) private view returns (int128) {
        return Currency.unwrap(_poolKey.currency0) == pairedCurrency
            ? int128(BalanceDelta.unwrap(delta) >> 128)
            : int128(BalanceDelta.unwrap(delta));
    }

    function _pairIsSpecified(SwapParams calldata params) private view returns (bool) {
        bool specifiedIs0 = (params.amountSpecified < 0) == params.zeroForOne;
        return specifiedIs0 == (Currency.unwrap(_poolKey.currency0) == pairedCurrency);
    }

    /// @dev Reverts intentionally, just like a v4 quoter. Only this contract may
    /// call it, inside beforeSwap. v4 skips callbacks for a hook's own swap.
    function quotePairedAmount(SwapParams calldata params) external {
        if (msg.sender != address(this)) revert OnlySelf();
        BalanceDelta delta = poolManager.swap(_poolKey, params, "");
        revert SwapQuote(_pairDelta(delta));
    }

    function _previewPairedAmount(SwapParams calldata params) private returns (uint256 executed) {
        uint256 requested = _specifiedAmount(params);
        (uint256 donation, uint256 buyback) = _fees(requested);
        SwapParams memory adjusted = params;
        adjusted.amountSpecified += int256(donation + buyback);
        try this.quotePairedAmount(adjusted) {
            revert InvalidAmount();
        } catch (bytes memory reason) {
            if (reason.length != 36 || bytes4(reason) != SwapQuote.selector) {
                assembly ("memory-safe") { revert(add(reason, 32), mload(reason)) }
            }
            int256 quoted;
            assembly ("memory-safe") { quoted := mload(add(reason, 36)) }
            executed = uint256(quoted < 0 ? -quoted : quoted);
        }
    }

    function _specifiedFees(SwapParams calldata params, uint256 executed)
        private
        view
        returns (uint256 donation, uint256 buyback)
    {
        uint256 requested = _specifiedAmount(params);
        (donation, buyback) = _fees(requested);
        uint256 intended = params.amountSpecified < 0 ? requested - donation - buyback : requested + donation + buyback;
        if (executed > intended) revert InvalidAmount();
        // Full fills charge the quoted fee; price-limited partial fills pay the
        // same fraction of each fee as the fraction actually executed. Returning
        // a smaller fee leaves more amount to swap, but an already reached price
        // limit still caps execution at exactly the previewed amount.
        donation = donation * executed / intended;
        buyback = buyback * executed / intended;
    }

    function _specifiedAmount(SwapParams calldata params) private pure returns (uint256 amount) {
        // Bounds also guarantee fee products and packed hook deltas cannot overflow.
        if (
            params.amountSpecified == 0 || params.amountSpecified > type(int128).max
                || params.amountSpecified < -int256(type(int128).max)
        ) revert InvalidAmount();
        amount = uint256(params.amountSpecified < 0 ? -params.amountSpecified : params.amountSpecified);
    }

    function _fees(uint256 amount) private view returns (uint256 donation, uint256 buyback) {
        donation = amount * antiSnipeFeeBps() / BPS;
        buyback = amount * BUYBACK_FEE_BPS / BPS;
    }

    function _checkPool(PoolKey calldata key) private view {
        if (!initialized || keccak256(abi.encode(key)) != poolId) revert InvalidPool();
    }

    function _checkOpen() private view {
        if (!initialized || block.number < poolOpenBlock) revert PoolNotOpen();
    }
}
