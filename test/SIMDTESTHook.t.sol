// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    SIMDTEST,
    SIMDTESTHook,
    IPoolManager,
    IHooks,
    Hooks,
    Currency,
    PoolKey,
    SwapParams,
    BalanceDelta,
    BeforeSwapDelta
} from "src/SIMDTESTHook.sol";

// Kept local because this repository has no vendored test dependencies.
interface HookVm {
    function roll(uint256) external;
    function prank(address) external;
    function expectRevert(bytes4) external;
    function expectRevert(bytes calldata) external;
    function etch(address, bytes calldata) external;
}

interface HookTestERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

contract HookPairedToken {
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public failingSender;
    uint8 public transferMode;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function configureTransfer(address sender, uint8 mode) external {
        failingSender = sender;
        transferMode = mode;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "pair allowance");
        if (allowance[from][msg.sender] != type(uint256).max) allowance[from][msg.sender] -= amount;
        _move(from, to, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        uint8 mode = msg.sender == failingSender ? transferMode : 0;
        if (mode == 1) return false;
        require(mode != 2, "pair transfer reverted");
        _move(msg.sender, to, amount);
        if (mode == 3) {
            assembly { return(0, 0) }
        }
        if (mode == 4) {
            assembly {
                mstore(0, 1)
                return(31, 1)
            }
        }
        if (mode == 5 && amount != 0) {
            balanceOf[to] -= 1;
            balanceOf[address(0xFEE)] += 1;
        }
        return true;
    }

    function _move(address from, address to, uint256 amount) private {
        require(balanceOf[from] >= amount, "pair balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @dev Accounting double, not an implementation of concentrated-liquidity math.
/// Quotes use two tokens per paired unit and the unchanged 1.25% LP input fee.
/// It models hook-return deltas, reverting previews, delayed router settlement,
/// ERC6909 claims, own-hook callback suppression, and balanced unlock boundaries.
/// Donation totals represent the credit to the sole in-range LP. Production v4
/// tick crossing / fee growth and the external launchpad's 1% fee are not modeled.
contract HookPoolManager is IPoolManager {
    SIMDTESTHook public hook;
    HookPairedToken public pair;
    SIMDTEST public token;
    PoolKey private key;
    bytes32 private stateSlot;
    bool public pairIs0;
    bool public active;
    uint128 public liquidity = 1 ether;
    uint160 public price = uint160(1 << 96);
    uint256 public executionCap = type(uint128).max;
    bool public exhaustRange;
    uint8 public badSwap;
    bool public omitCallback;
    bool public tryReentry;
    bytes4 public reentryError;
    bytes public swapFailure;
    int256 public hookPairDelta;
    int256 public hookTokenDelta;
    uint256 public claims;
    uint256 public claimMints;
    uint256 public claimBurns;
    uint256 public donated0;
    uint256 public donated1;
    uint256 public swapCalls;
    uint256 public unlockCalls;
    uint256 public syncedBalance;
    uint256 public beforeFee;
    uint256 public afterFee;
    uint256 public executedPair;
    int256 public lastSpecified;
    uint160 public lastLimit;
    bool public lastDirection;
    uint24 public lastFee;

    function configure(SIMDTESTHook h, HookPairedToken p, SIMDTEST t, PoolKey memory k) external {
        hook = h;
        pair = p;
        token = t;
        key = k;
        pairIs0 = Currency.unwrap(k.currency0) == address(p);
        stateSlot = keccak256(abi.encode(keccak256(abi.encode(k)), uint256(6)));
    }

    function initialize(address sender, PoolKey memory k, uint160 sqrtPrice) external returns (bytes4) {
        return hook.beforeInitialize(sender, k, sqrtPrice);
    }

    function setLiquidity(uint128 value) external {
        liquidity = value;
    }

    function setPrice(uint160 value) external {
        price = value;
    }

    function setCap(uint256 value) external {
        executionCap = value;
    }

    function setExhaustRange(bool value) external {
        exhaustRange = value;
    }

    function setBadSwap(uint8 value) external {
        badSwap = value;
    }

    function setOmitCallback(bool value) external {
        omitCallback = value;
    }

    function setTryReentry(bool value) external {
        tryReentry = value;
    }

    function setSwapFailure(bytes calldata value) external {
        swapFailure = value;
    }

    function drainPair(address to) external {
        require(pair.transfer(to, pair.balanceOf(address(this))), "drain transfer");
    }

    function trade(SwapParams memory params) external returns (int256 userPair, int256 userToken) {
        require(!active, "manager locked");
        active = true;
        (bytes4 beforeSelector, BeforeSwapDelta feeDelta, uint24 overrideFee) =
            hook.beforeSwap(msg.sender, key, params, "");
        require(beforeSelector == IHooks.beforeSwap.selector && overrideFee == 0, "before response / LP override");
        require(int128(BeforeSwapDelta.unwrap(feeDelta)) == 0, "unexpected unspecified before fee");
        beforeFee = uint256(int256(int128(BeforeSwapDelta.unwrap(feeDelta) >> 128)));
        SwapParams memory adjusted =
            SwapParams(params.zeroForOne, params.amountSpecified + int256(beforeFee), params.sqrtPriceLimitX96);
        BalanceDelta delta = _core(key, adjusted);
        (int128 p, int128 t) = split(delta);
        executedPair = uint256(p < 0 ? -int256(p) : int256(p));
        (bytes4 afterSelector, int128 returnedFee) = hook.afterSwap(msg.sender, key, params, delta, "");
        require(afterSelector == IHooks.afterSwap.selector && returnedFee >= 0, "after response");
        afterFee = uint256(int256(returnedFee));
        hookPairDelta += int256(beforeFee + afterFee);
        userPair = int256(p) - int256(beforeFee + afterFee);
        userToken = int256(t);
        _payUser(HookTestERC20(address(pair)), userPair);
        _payUser(HookTestERC20(address(token)), userToken);
        _close();
    }

    function _payUser(HookTestERC20 currency, int256 delta) private {
        if (delta < 0) require(currency.transferFrom(msg.sender, address(this), uint256(-delta)), "router payment");
        else if (delta > 0) require(currency.transfer(msg.sender, uint256(delta)), "router receipt");
    }

    function unlock(bytes calldata data) external returns (bytes memory result) {
        require(msg.sender == address(hook) && !active, "unlock caller / lock");
        active = true;
        unlockCalls++;
        if (omitCallback) {
            active = false;
            return abi.encode(uint256(0), uint256(0));
        }
        result = hook.unlockCallback(data);
        _close();
    }

    function _close() private {
        require(hookPairDelta == 0 && hookTokenDelta == 0, "unsettled hook currency");
        active = false;
    }

    function swap(PoolKey calldata k, SwapParams calldata params, bytes calldata)
        external
        returns (BalanceDelta delta)
    {
        require(active && msg.sender == address(hook), "swap caller / lock");
        if (swapFailure.length != 0) {
            bytes memory reason = swapFailure;
            assembly { revert(add(reason, 32), mload(reason)) }
        }
        if (tryReentry) {
            (bool ok, bytes memory reason) = address(hook).call(abi.encodeWithSignature("buybackAndBurn()"));
            require(!ok && reason.length == 4, "reentry succeeded");
            reentryError = bytes4(reason);
        }
        delta = _core(k, params);
        (int128 p, int128 t) = split(delta);
        if (badSwap == 1) {
            p = 0;
            t = 0;
        }
        if (badSwap == 2) p = 1;
        if (badSwap == 3) t = -1;
        if (badSwap == 4) p = -int128(uint128(uint256(-params.amountSpecified) + 1));
        delta = pack(p, t);
        hookPairDelta += p;
        hookTokenDelta += t;
    }

    function _core(PoolKey memory k, SwapParams memory params) private returns (BalanceDelta) {
        require(keccak256(abi.encode(k)) == keccak256(abi.encode(key)), "wrong pool");
        require(k.fee == 12_500, "changed LP fee");
        bool pairInput = params.zeroForOne == pairIs0;
        bool exactInput = params.amountSpecified < 0;
        uint256 specified = uint256(exactInput ? -params.amountSpecified : params.amountSpecified);
        if (specified > executionCap) specified = executionCap;
        if (liquidity == 0) specified = 0;
        uint256 p;
        uint256 t;
        if (pairInput) {
            if (exactInput) {
                p = specified;
                t = p * 19_750 / 10_000;
            } else {
                t = specified;
                p = (t * 10_000 + 19_749) / 19_750;
            }
        } else {
            if (exactInput) {
                t = specified;
                p = t * 9_875 / 20_000;
            } else {
                p = specified;
                t = (p * 20_000 + 9_874) / 9_875;
            }
        }
        require(
            p <= uint256(uint128(type(int128).max)) && t <= uint256(uint128(type(int128).max)), "model delta overflow"
        );
        swapCalls++;
        lastSpecified = params.amountSpecified;
        lastLimit = params.sqrtPriceLimitX96;
        lastDirection = params.zeroForOne;
        lastFee = k.fee;
        if (exhaustRange) liquidity = 0;
        return pack(
            pairInput ? -int128(uint128(p)) : int128(uint128(p)), pairInput ? int128(uint128(t)) : -int128(uint128(t))
        );
    }

    function donate(PoolKey calldata k, uint256 amount0, uint256 amount1, bytes calldata)
        external
        returns (BalanceDelta)
    {
        require(active && msg.sender == address(hook) && liquidity > 0, "donation caller / liquidity");
        require(keccak256(abi.encode(k)) == keccak256(abi.encode(key)), "donation pool");
        require(pairIs0 ? amount1 == 0 : amount0 == 0, "donated launch token");
        donated0 += amount0;
        donated1 += amount1;
        uint256 amount = amount0 + amount1;
        hookPairDelta -= int256(amount);
        return pack(-int128(uint128(amount)), 0);
    }

    function take(Currency c, address to, uint256 amount) external {
        require(active && msg.sender == address(hook), "take caller / lock");
        if (Currency.unwrap(c) == address(pair)) {
            hookPairDelta -= int256(amount);
        } else {
            require(Currency.unwrap(c) == address(token), "unknown currency");
            hookTokenDelta -= int256(amount);
        }
        require(HookTestERC20(Currency.unwrap(c)).transfer(to, amount), "take transfer");
    }

    function mint(address to, uint256 id, uint256 amount) external {
        require(
            active && msg.sender == address(hook) && to == address(hook) && id == uint160(address(pair)), "claim mint"
        );
        claims += amount;
        claimMints += amount;
        hookPairDelta -= int256(amount);
    }

    function burn(address from, uint256 id, uint256 amount) external {
        require(
            active && msg.sender == address(hook) && from == address(hook) && id == uint160(address(pair)), "claim burn"
        );
        claims -= amount;
        claimBurns += amount;
        hookPairDelta += int256(amount);
    }

    function sync(Currency c) external {
        require(active && msg.sender == address(hook) && Currency.unwrap(c) == address(pair), "sync currency / caller");
        syncedBalance = pair.balanceOf(address(this));
    }

    function settle() external payable returns (uint256 paid) {
        require(active && msg.sender == address(hook) && msg.value == 0, "settle caller / value");
        paid = pair.balanceOf(address(this)) - syncedBalance;
        hookPairDelta += int256(paid);
    }

    function extsload(bytes32 slot) external view returns (bytes32) {
        if (slot == stateSlot) return bytes32(uint256(price));
        require(slot == bytes32(uint256(stateSlot) + 3), "unexpected v4 storage slot");
        return bytes32(uint256(liquidity));
    }

    function pack(int128 p, int128 t) public view returns (BalanceDelta) {
        (int128 a, int128 b) = pairIs0 ? (p, t) : (t, p);
        return BalanceDelta.wrap((int256(a) << 128) | int256(uint256(uint128(b))));
    }

    function split(BalanceDelta delta) public view returns (int128 p, int128 t) {
        int128 a = int128(BalanceDelta.unwrap(delta) >> 128);
        int128 b = int128(BalanceDelta.unwrap(delta));
        return pairIs0 ? (a, b) : (b, a);
    }
}

abstract contract HookFixture {
    HookVm internal constant vm = HookVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address internal constant ALICE = address(0xA11CE);
    uint160 internal constant Q96 = uint160(1 << 96);
    uint256 internal constant OPEN = 100;
    SIMDTESTHook internal hook;
    SIMDTEST internal token;
    HookPairedToken internal pair;
    HookPoolManager internal manager;
    PoolKey internal key;

    function _pairAddress() internal pure virtual returns (address) {
        return address(0x1000);
    }

    function setUp() public virtual {
        vm.roll(90);
        HookPairedToken template = new HookPairedToken();
        vm.etch(_pairAddress(), address(template).code);
        pair = HookPairedToken(_pairAddress());
        token = new SIMDTEST();
        manager = new HookPoolManager();
        hook = _deploy(manager, address(pair), OPEN);
        bool pair0 = address(pair) < address(token);
        key = PoolKey(
            Currency.wrap(pair0 ? address(pair) : address(token)),
            Currency.wrap(pair0 ? address(token) : address(pair)),
            12_500,
            60,
            IHooks(address(hook))
        );
        manager.configure(hook, pair, token, key);
        require(manager.initialize(address(this), key, Q96) == IHooks.beforeInitialize.selector, "init selector");
        // The test acts as the external launch factory; allocations are not made by the hook.
        token.transfer(address(manager), token.POOL_ALLOCATION());
        token.transfer(token.HACKATHON_RECIPIENT(), token.HACKATHON_ALLOCATION());
        pair.mint(address(manager), 1e30);
        pair.mint(address(this), 1e30);
        pair.approve(address(manager), type(uint256).max);
        token.approve(address(manager), type(uint256).max);
    }

    function _deploy(IPoolManager pm, address paired, uint256 open) internal returns (SIMDTESTHook deployed) {
        bytes memory initCode = abi.encodePacked(type(SIMDTESTHook).creationCode, abi.encode(pm, paired, open));
        bytes32 codeHash = keccak256(initCode);
        bytes32 salt;
        for (uint256 i;; i++) {
            salt = bytes32(i);
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, codeHash)))));
            if (uint160(predicted) & 0x3fff == 0x20cc && predicted.code.length == 0) break;
        }
        deployed = new SIMDTESTHook{salt: salt}(pm, paired, open);
    }

    function _params(uint256 amount, bool pairInput, bool exactInput) internal view returns (SwapParams memory) {
        return SwapParams(
            pairInput == manager.pairIs0(),
            exactInput ? -int256(amount) : int256(amount),
            pairInput == manager.pairIs0()
                ? uint160(4_295_128_740)
                : uint160(1461446703485210103287273052203988822378723970341)
        );
    }

    function _eq(uint256 actual, uint256 expected, string memory why) internal pure {
        require(actual == expected, why);
    }

    function _eqInt(int256 actual, int256 expected, string memory why) internal pure {
        require(actual == expected, why);
    }

    function _assertReserves() internal view {
        _eq(
            pair.balanceOf(address(hook)) + hook.pairedClaims(),
            hook.accumulatedPairedFees() + hook.pendingDonation(),
            "reserves not backed"
        );
        _eq(hook.pairedClaims(), manager.claims(), "claim ledger mismatch");
        _eq(pair.balanceOf(DEAD), 0, "paired ERC20 burned");
        _eq(token.balanceOf(address(hook)), 0, "launch tokens trapped in hook");
        _eqInt(manager.hookPairDelta(), 0, "unsettled paired delta");
        _eqInt(manager.hookTokenDelta(), 0, "unsettled token delta");
    }
}

/// forge-config: default.fuzz.runs = 256
abstract contract HookBehaviorTests is HookFixture {
    struct TradeSnapshot {
        uint256 fees;
        uint256 donation;
        uint256 pairBalance;
        uint256 tokenBalance;
        uint256 calls;
    }

    function testDeploymentAndPermissions() public view {
        _eq(uint160(address(hook)) & 0x3fff, hook.HOOK_FLAGS(), "CREATE2 flags");
        require(address(hook.poolManager()) == address(manager) && hook.pairedCurrency() == address(pair), "immutables");
        require(hook.initializer() == address(this) && hook.token() == address(token), "initializer / token");
        _eq(hook.earliestOpenBlock(), OPEN, "earliest block");
        _eq(hook.poolOpenBlock(), OPEN, "open block");
        require(hook.poolId() == keccak256(abi.encode(key)), "pool id");
        require(keccak256(abi.encode(hook.getPoolKey())) == keccak256(abi.encode(key)), "stored key");
        Hooks.Permissions memory p = hook.getHookPermissions();
        require(
            p.beforeInitialize && p.beforeSwap && p.afterSwap && p.beforeSwapReturnDelta && p.afterSwapReturnDelta,
            "missing permissions"
        );
        require(
            !p.afterInitialize && !p.beforeAddLiquidity && !p.afterAddLiquidity && !p.beforeRemoveLiquidity
                && !p.afterRemoveLiquidity && !p.beforeDonate && !p.afterDonate && !p.afterAddLiquidityReturnDelta
                && !p.afterRemoveLiquidityReturnDelta,
            "excess permissions"
        );
        _eq(hook.POOL_FEE(), 12_500, "LP fee");
        _eq(hook.BUYBACK_FEE_BPS(), 50, "buyback rate");
    }

    function testCannotTradeOrBuybackBeforeOpen() public {
        _eq(hook.antiSnipeFeeBps(), 0, "fee before opening");
        SwapParams memory params = _params(10_000, true, true);
        vm.expectRevert(SIMDTESTHook.PoolNotOpen.selector);
        manager.trade(params);
        BalanceDelta delta = manager.pack(-10_000, 19_750);
        vm.expectRevert(SIMDTESTHook.PoolNotOpen.selector);
        vm.prank(address(manager));
        hook.afterSwap(ALICE, key, params, delta, "");
        vm.expectRevert(SIMDTESTHook.PoolNotOpen.selector);
        hook.buybackAndBurn();
        _assertReserves();
    }

    function testAntiSnipeEveryBlockAndAllSwapModes() public {
        for (uint256 elapsed; elapsed <= 11; elapsed++) {
            vm.roll(OPEN + elapsed);
            uint256 bps = elapsed < 10 ? 3000 - 300 * elapsed : 0;
            _eq(hook.antiSnipeFeeBps(), bps, "linear block rate");
            for (uint256 mode; mode < 4; mode++) {
                _checkTrade(1_000_000, mode < 2, mode % 2 == 0, bps, type(uint128).max);
            }
        }
        vm.roll(OPEN + 1_000_000);
        _checkTrade(1_000_000, false, true, 0, type(uint128).max);
    }

    function _checkTrade(uint256 amount, bool pairInput, bool exactInput, uint256 bps, uint256 cap) internal {
        TradeSnapshot memory old = TradeSnapshot(
            hook.accumulatedPairedFees(),
            manager.donated0() + manager.donated1(),
            pair.balanceOf(address(this)),
            token.balanceOf(address(this)),
            manager.swapCalls()
        );
        manager.setCap(cap);
        {
            (int256 p, int256 t) = manager.trade(_params(amount, pairInput, exactInput));
            _eqInt(int256(pair.balanceOf(address(this))) - int256(old.pairBalance), p, "trader paired settlement");
            _eqInt(int256(token.balanceOf(address(this))) - int256(old.tokenBalance), t, "trader token settlement");
        }
        uint256 executed = manager.executedPair();
        bool pairSpecified = pairInput == exactInput;
        uint256 donation;
        uint256 fee;
        if (pairSpecified) {
            donation = amount * bps / 10_000;
            fee = amount / 200;
            uint256 intended = exactInput ? amount - donation - fee : amount + donation + fee;
            uint256 expectedExecuted = intended < cap ? intended : cap;
            _eq(executed, expectedExecuted, "specified execution");
            donation = donation * expectedExecuted / intended;
            fee = fee * expectedExecuted / intended;
            _eq(manager.beforeFee(), donation + fee, "specified before fee");
            _eq(manager.afterFee(), 0, "specified double charge");
            if (cap >= intended) {
                _eqInt(
                    int256(pair.balanceOf(address(this))) - int256(old.pairBalance),
                    pairInput ? -int256(amount) : int256(amount),
                    "specified user budget"
                );
            }
        } else {
            // Independently derive the paired execution at the model's 2:1 price and LP fee.
            uint256 fill = amount < cap ? amount : cap;
            uint256 expectedExecuted = pairInput ? (fill * 10_000 + 19_749) / 19_750 : fill * 9875 / 20_000;
            _eq(executed, expectedExecuted, "unspecified executed pair");
            donation = expectedExecuted * bps / 10_000;
            fee = expectedExecuted / 200;
            _eq(manager.beforeFee(), 0, "token-specified before fee");
            _eq(manager.afterFee(), donation + fee, "unspecified after fee");
        }
        _eq(hook.accumulatedPairedFees() - old.fees, fee, "0.5% reserve");
        _eq(manager.donated0() + manager.donated1() - old.donation, donation, "LP donation");
        _eq(manager.pairIs0() ? manager.donated1() : manager.donated0(), 0, "wrong donation currency");
        _eq(manager.swapCalls() - old.calls, 1, "preview left pool state behind");
        _eq(manager.lastFee(), 12_500, "LP fee changed");
        _assertReserves();
    }

    function testFuzzFeesRoundingAndPartialFills(
        uint128 seed,
        uint8 blockSeed,
        bool pairInput,
        bool exactInput,
        uint128 capSeed
    ) public {
        uint256 amount = 1 + uint256(seed) % 1e22;
        uint256 elapsed = uint256(blockSeed) % 16;
        uint256 cap = uint256(capSeed) % (amount + 1);
        vm.roll(OPEN + elapsed);
        _checkTrade(amount, pairInput, exactInput, elapsed < 10 ? 3000 - elapsed * 300 : 0, cap);
    }

    function testDustAndZeroFillDoNotChargeUnexecutedFees() public {
        vm.roll(OPEN);
        for (uint256 amount = 1; amount <= 4; amount++) {
            _checkTrade(amount, true, true, 3000, type(uint128).max);
            _checkTrade(amount, false, false, 3000, type(uint128).max);
        }
        _checkTrade(1 ether, true, true, 3000, 0);
        _checkTrade(1 ether, false, false, 3000, 0);
    }

    function testPartialPairSpecifiedFillsHaveExactProportionalFees() public {
        vm.roll(OPEN);
        _checkTrade(10_000, true, true, 3000, 1390); // 20% of the 6950 net input.
        _checkTrade(10_000, false, false, 3000, 2610); // 20% of the 13050 gross output.
    }

    function testMaximumSpecifiedBudgetsAreSafeForPartialFills() public {
        vm.roll(OPEN);
        uint256 max = uint256(uint128(type(int128).max));
        _checkTrade(max, true, true, 3000, 1e20);
        _checkTrade(max, false, false, 3000, 1e20);
    }

    function testBuybackFlushesDeferredDonationAtomically() public {
        vm.roll(OPEN);
        manager.drainPair(address(this));
        manager.setExhaustRange(true);
        manager.trade(_params(10_000, true, true));
        _eq(hook.pendingDonation(), 3000, "pending donation");
        _eq(hook.pairedClaims(), 3050, "claim reserves");
        manager.setExhaustRange(false);
        manager.setLiquidity(1 ether);
        // Flushing happens before the swap, but a failed output check must undo it.
        vm.expectRevert(SIMDTESTHook.InsufficientOutput.selector);
        hook.buybackAndBurn(99);
        _eq(hook.pendingDonation(), 3000, "failed buyback flushed donation");
        _eq(manager.donated0() + manager.donated1(), 0, "failed buyback credited LP");
        _eq(hook.pairedClaims(), 3050, "failed buyback spent claims");
        _eq(hook.buybackAndBurn(98), 98, "buyback output");
        _eq(manager.donated0() + manager.donated1(), 3000, "buyback did not credit donation");
        _eq(hook.pendingDonation(), 0, "buyback did not flush");
        _eq(manager.claimBurns(), 3050, "donation / buyback claims not redeemed");
        _assertReserves();
    }

    function testLiquidityGapCannotConsumeFeesAndRecoveryAllowsTrading() public {
        vm.roll(OPEN);
        manager.setExhaustRange(true);
        manager.trade(_params(10_000, true, true));
        manager.setExhaustRange(false);
        vm.expectRevert(SIMDTESTHook.InsufficientOutput.selector);
        hook.buybackAndBurn();
        _eq(hook.accumulatedPairedFees(), 50, "liquidity gap consumed fees");
        _eq(hook.pendingDonation(), 3000, "liquidity gap consumed donation");
        // A zero fill during the gap charges nothing and preserves both reserves.
        manager.trade(_params(10_000, false, true));
        _eq(hook.accumulatedPairedFees(), 50, "zero fill charged fee");
        _eq(hook.pendingDonation(), 3000, "zero fill changed pending donation");
        manager.setLiquidity(1 ether);
        manager.trade(_params(10_000, false, true));
        require(hook.buybackAndBurn() > 0, "liquidity recovery trapped funds");
        _assertReserves();
    }

    function testDeferredDonationFlushesWithoutSpendingBuybackReserve() public {
        vm.roll(OPEN);
        manager.setExhaustRange(true);
        manager.trade(_params(10_000, true, true));
        _eq(hook.pendingDonation(), 3000, "deferred donation");
        _eq(hook.accumulatedPairedFees(), 50, "separate buyback reserve");
        _eq(pair.balanceOf(address(hook)), 3050, "held reserves");
        _eq(manager.donated0() + manager.donated1(), 0, "donated without liquidity");
        _assertReserves();
        manager.setExhaustRange(false);
        manager.setLiquidity(1 ether);
        vm.roll(OPEN + 10);
        manager.trade(_params(10_000, true, true));
        _eq(hook.pendingDonation(), 0, "donation not flushed");
        _eq(manager.donated0() + manager.donated1(), 3000, "flush credited LP");
        _eq(hook.accumulatedPairedFees(), 100, "flush consumed buyback fees");
        _assertReserves();
    }

    function testEmptyManagerCreatesBackedClaimsAndBuybackRedeemsThem() public {
        vm.roll(OPEN);
        manager.drainPair(address(this));
        manager.trade(_params(1_000_000, true, true));
        _eq(hook.pairedClaims(), 5000, "claim fallback");
        _eq(pair.balanceOf(address(hook)), 0, "unexpected cash");
        _eq(manager.claimMints(), 5000, "claim amount");
        _assertReserves();
        _eq(hook.buybackAndBurn(), 9875, "claims buyback output");
        _eq(manager.claimBurns(), 5000, "claims not redeemed");
        _eq(pair.totalSupply(), 2e30, "ERC6909 burn changed paired supply");
        _assertReserves();
    }

    function testBuybackFlushesDeferredClaimsThenUsesCash() public {
        vm.roll(OPEN);
        manager.drainPair(address(this));
        manager.setExhaustRange(true);
        manager.trade(_params(10_000, true, true));
        _eq(hook.pairedClaims(), 3050, "deferred claim reserve");
        manager.setExhaustRange(false);
        manager.setLiquidity(1 ether);
        vm.roll(OPEN + 10);
        manager.trade(_params(10_000, true, true));
        _eq(hook.pairedClaims(), 50, "donation must consume claims first");
        _eq(pair.balanceOf(address(hook)), 50, "new cash fee");
        _eq(hook.buybackAndBurn(), 197, "mixed settlement buyback");
        _eq(manager.claimBurns(), 3050, "mixed claims redeemed");
        _eq(hook.pendingDonation(), 0, "donation remains");
        _assertReserves();
    }

    function testBuybackIsPermissionlessAndBurnsOnlyLaunchTokens() public {
        vm.roll(OPEN + 10);
        manager.trade(_params(1_000_000, true, true));
        uint256 calls = manager.swapCalls();
        uint256 pairedSupply = pair.totalSupply();
        vm.prank(ALICE);
        uint256 burned = hook.buybackAndBurn();
        _eq(burned, 9875, "buyback output after unchanged LP fee");
        _eq(token.balanceOf(DEAD), burned, "tokens not at burn address");
        _eq(token.totalSupply(), 1_000_000_000 ether, "nominal fixed supply changed");
        _eq(token.totalSupply() - token.balanceOf(DEAD), 1_000_000_000 ether - burned, "effective circulating supply");
        _eq(hook.accumulatedPairedFees(), 0, "fees not spent");
        _eq(token.balanceOf(ALICE), 0, "caller received tokens");
        _eq(pair.balanceOf(ALICE), 0, "caller received paired fees");
        _eq(pair.totalSupply(), pairedSupply, "paired currency burned");
        _eq(manager.swapCalls() - calls, 1, "recursive hook swap");
        _eq(manager.lastFee(), 12_500, "buyback LP fee");
        require(manager.lastDirection() == manager.pairIs0(), "buyback direction");
        _eq(manager.lastLimit(), uint256(Q96) * (manager.pairIs0() ? 9900 : 10100) / 10_000, "reference price limit");
        _eq(hook.buybackAndBurn(), 0, "repeat empty buyback");
        _eq(manager.unlockCalls(), 1, "empty buyback unlocked manager");
        _assertReserves();
    }

    function testPartialBuybackPreservesUnspentReserveForAnyone() public {
        vm.roll(OPEN + 10);
        manager.trade(_params(1_000_000, true, true));
        manager.setCap(2000);
        _eq(hook.buybackAndBurn(3950), 3950, "partial output");
        _eq(hook.accumulatedPairedFees(), 3000, "partial remaining reserve");
        _assertReserves();
        manager.setCap(type(uint128).max);
        vm.prank(address(0xB0B));
        _eq(hook.buybackAndBurn(), 5925, "second caller redemption");
        _eq(token.balanceOf(DEAD), 9875, "total burned");
        _assertReserves();
    }

    function testBuybackMinimumFailureRollsBackThenCanRetry() public {
        vm.roll(OPEN + 10);
        manager.trade(_params(1_000_000, true, true));
        vm.expectRevert(SIMDTESTHook.InvalidAmount.selector);
        hook.buybackAndBurn(0);
        vm.expectRevert(SIMDTESTHook.InsufficientOutput.selector);
        hook.buybackAndBurn(9876);
        _eq(hook.accumulatedPairedFees(), 5000, "failed minimum consumed fees");
        _eq(token.balanceOf(DEAD), 0, "failed minimum burned tokens");
        _eq(manager.unlockCalls(), 0, "failed unlock mutated state");
        _assertReserves();
        _eq(hook.buybackAndBurn(9875), 9875, "retry after failed minimum");
    }

    function testMalformedBuybackDeltasRevertAtomically() public {
        vm.roll(OPEN + 10);
        manager.trade(_params(1_000_000, true, true));
        for (uint8 mode = 1; mode <= 4; mode++) {
            manager.setBadSwap(mode);
            vm.expectRevert(SIMDTESTHook.InsufficientOutput.selector);
            hook.buybackAndBurn();
            _eq(hook.accumulatedPairedFees(), 5000, "bad output consumed reserve");
            _eq(token.balanceOf(DEAD), 0, "bad output burned tokens");
            _assertReserves();
        }
        manager.setBadSwap(0);
        _eq(hook.buybackAndBurn(), 9875, "retry after bad deltas");
    }

    function testTransferAndSettlementFailuresPreserveReserve() public {
        vm.roll(OPEN + 10);
        manager.trade(_params(1_000_000, true, true));
        for (uint8 mode = 1; mode <= 5; mode++) {
            if (mode == 3) continue; // No-return ERC20 transfers are valid and tested separately.
            pair.configureTransfer(address(hook), mode);
            vm.expectRevert(mode == 5 ? SIMDTESTHook.SettlementMismatch.selector : SIMDTESTHook.TransferFailed.selector);
            hook.buybackAndBurn();
            _eq(hook.accumulatedPairedFees(), 5000, "transfer failure consumed fees");
            _eq(token.balanceOf(DEAD), 0, "failed settlement burned tokens");
            _assertReserves();
        }
        pair.configureTransfer(address(hook), 3);
        _eq(hook.buybackAndBurn(), 9875, "no-return token unsupported");
        _assertReserves();
    }

    function testUnlockMustBeExpectedAndReentrancyIsRejected() public {
        vm.expectRevert(SIMDTESTHook.UnexpectedUnlock.selector);
        vm.prank(address(manager));
        hook.unlockCallback(abi.encode(uint256(1), uint256(1)));
        vm.roll(OPEN + 10);
        manager.trade(_params(1_000_000, true, true));
        manager.setOmitCallback(true);
        vm.expectRevert(SIMDTESTHook.UnexpectedUnlock.selector);
        hook.buybackAndBurn();
        _eq(hook.accumulatedPairedFees(), 5000, "missing callback consumed fees");
        manager.setOmitCallback(false);
        manager.setTryReentry(true);
        _eq(hook.buybackAndBurn(), 9875, "outer buyback failed");
        require(manager.reentryError() == SIMDTESTHook.Reentrancy.selector, "wrong reentry failure");
        _assertReserves();
    }

    function testManipulatedSpotCannotReplacePriorReferenceInSameBlock() public {
        vm.roll(OPEN + 10);
        manager.trade(_params(1_000_000, true, true));
        uint160 adverse = uint160(uint256(Q96) * (manager.pairIs0() ? 9800 : 10200) / 10_000);
        manager.setPrice(adverse);
        manager.trade(_params(1_000_000, false, true));
        _eq(hook.buybackReferenceSqrtPriceX96(), Q96, "same-block manipulated reference");
        uint256 fees = hook.accumulatedPairedFees();
        vm.expectRevert(SIMDTESTHook.BuybackPriceLimit.selector);
        hook.buybackAndBurn();
        _eq(hook.accumulatedPairedFees(), fees, "price rejection consumed fees");
        // Ordinary trades remain possible while a buyback is price-protected.
        manager.setPrice(Q96);
        manager.trade(_params(1_000_000, true, true));
        require(hook.buybackAndBurn() > 0, "price recovery trapped reserve");
        _assertReserves();
    }

    function testNextBlockUsesLastObservedPrice() public {
        vm.roll(OPEN);
        uint160 observed = uint160(uint256(Q96) * 10_050 / 10_000);
        manager.setPrice(observed);
        manager.trade(_params(1_000_000, true, true));
        _eq(hook.buybackReferenceSqrtPriceX96(), Q96, "first reference");
        vm.roll(OPEN + 1);
        manager.trade(_params(1_000_000, true, true));
        _eq(hook.buybackReferenceSqrtPriceX96(), observed, "prior observed block reference");
    }

    function testExternalAccountsCannotForgeCallbacksOrQuote() public {
        SwapParams memory params = _params(10_000, true, true);
        BalanceDelta delta = manager.pack(-10_000, 19_750);
        vm.expectRevert(SIMDTESTHook.OnlyPoolManager.selector);
        hook.beforeInitialize(address(this), key, Q96);
        vm.expectRevert(SIMDTESTHook.OnlyPoolManager.selector);
        hook.beforeSwap(address(this), key, params, "");
        vm.expectRevert(SIMDTESTHook.OnlyPoolManager.selector);
        hook.afterSwap(address(this), key, params, delta, "");
        vm.expectRevert(SIMDTESTHook.OnlyPoolManager.selector);
        hook.unlockCallback(abi.encode(uint256(1), uint256(1)));
        vm.expectRevert(SIMDTESTHook.OnlySelf.selector);
        hook.quotePairedAmount(params);
    }

    function testInitializedPoolCannotBeReplacedAndForeignKeysCannotTrade() public {
        vm.expectRevert(SIMDTESTHook.UnauthorizedInitialization.selector);
        manager.initialize(address(this), key, Q96);
        vm.roll(OPEN);
        PoolKey memory wrong = key;
        wrong.tickSpacing++;
        SwapParams memory params = _params(10_000, true, true);
        BalanceDelta delta = manager.pack(-10_000, 19_750);
        vm.expectRevert(SIMDTESTHook.InvalidPool.selector);
        vm.prank(address(manager));
        hook.beforeSwap(ALICE, wrong, params, "");
        vm.expectRevert(SIMDTESTHook.InvalidPool.selector);
        vm.prank(address(manager));
        hook.afterSwap(ALICE, wrong, params, delta, "");
        _eq(hook.poolOpenBlock(), OPEN, "reinitialization reset window");
    }

    function testSpecifiedInvalidAmountsAndPoolErrorsBubble() public {
        vm.roll(OPEN);
        int256[4] memory amounts =
            [int256(0), int256(type(int128).max) + 1, -int256(type(int128).max) - 1, type(int256).min];
        for (uint256 i; i < amounts.length; i++) {
            bool pairInput = amounts[i] < 0;
            SwapParams memory params = SwapParams(pairInput == manager.pairIs0(), amounts[i], Q96);
            vm.expectRevert(SIMDTESTHook.InvalidAmount.selector);
            manager.trade(params);
        }
        bytes memory reason = abi.encodeWithSignature("PoolLiquidityFailure(uint256)", uint256(7));
        manager.setSwapFailure(reason);
        SwapParams memory validParams = _params(10_000, true, true);
        vm.expectRevert(reason);
        manager.trade(validParams);
        _eq(hook.accumulatedPairedFees(), 0, "failed preview collected fees");
        _eq(manager.swapCalls(), 0, "failed preview changed pool");
        _assertReserves();
    }

    function testInvalidConfigurationRejected() public {
        vm.expectRevert(SIMDTESTHook.InvalidConfiguration.selector);
        new SIMDTESTHook(IPoolManager(address(0)), address(pair), OPEN);
        vm.expectRevert(SIMDTESTHook.InvalidConfiguration.selector);
        new SIMDTESTHook(manager, address(0), OPEN);
    }

    function testInitializationValidationAndDelayedOpening() public {
        SIMDTESTHook fresh = _deploy(manager, address(pair), 0);
        _eq(fresh.antiSnipeFeeBps(), 0, "uninitialized rate");
        vm.expectRevert(SIMDTESTHook.PoolNotOpen.selector);
        fresh.buybackAndBurn();
        PoolKey memory good = key;
        good.hooks = IHooks(address(fresh));
        vm.expectRevert(SIMDTESTHook.UnauthorizedInitialization.selector);
        vm.prank(address(manager));
        fresh.beforeInitialize(ALICE, good, Q96);
        for (uint256 i; i < 6; i++) {
            PoolKey memory bad = PoolKey(good.currency0, good.currency1, good.fee, good.tickSpacing, good.hooks);
            if (i == 0) bad.fee = 10_000;
            if (i == 1) bad.tickSpacing = 0;
            if (i == 2) bad.hooks = IHooks(ALICE);
            if (i == 3) (bad.currency0, bad.currency1) = (good.currency1, good.currency0);
            if (i == 4) {
                bad.currency0 = Currency.wrap(address(1));
                bad.currency1 = Currency.wrap(address(2));
            }
            if (i == 5) {
                if (manager.pairIs0()) bad.currency1 = Currency.wrap(address(uint160(address(pair)) + 1));
                else bad.currency0 = Currency.wrap(address(uint160(address(pair)) - 1));
            }
            vm.expectRevert(SIMDTESTHook.InvalidPool.selector);
            vm.prank(address(manager));
            fresh.beforeInitialize(address(this), bad, Q96);
            require(!fresh.initialized(), "failed init changed state");
        }
        vm.roll(OPEN + 50);
        vm.prank(address(manager));
        fresh.beforeInitialize(address(this), good, Q96);
        _eq(fresh.poolOpenBlock(), OPEN + 50, "zero earliest block did not open at initialization");
        _eq(fresh.antiSnipeFeeBps(), 3000, "late initialization lost protection");

        SIMDTESTHook delayed = _deploy(manager, address(pair), OPEN);
        good.hooks = IHooks(address(delayed));
        vm.prank(address(manager));
        delayed.beforeInitialize(address(this), good, Q96);
        _eq(delayed.poolOpenBlock(), OPEN + 50, "past scheduled block used as opening");
        _eq(delayed.antiSnipeFeeBps(), 3000, "delayed rate");
    }
}

contract SIMDTESTHookCurrency0Test is HookBehaviorTests {}

contract SIMDTESTHookCurrency1Test is HookBehaviorTests {
    function _pairAddress() internal pure override returns (address) {
        return address(type(uint160).max - 1);
    }
}

/// @dev Only these bounded actions are fuzz targets. Unexpected reverts fail the
/// campaign; deliberately failing buybacks verify their exact error and rollback.
contract HookInvariantHandler {
    HookVm private constant vm = HookVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    SIMDTESTHook public immutable hook;
    HookPoolManager public immutable manager;
    HookPairedToken public immutable pair;
    SIMDTEST public immutable token;
    uint256 public expectedFees;
    uint256 public expectedDonations;
    uint256 public pairedSpent;
    uint256 public tokensBurned;
    uint256 public successfulSwaps;
    uint256 public successfulBuybacks;
    uint256 public rejectedBuybacks;

    constructor(SIMDTESTHook h, HookPoolManager m, HookPairedToken p, SIMDTEST t) {
        hook = h;
        manager = m;
        pair = p;
        token = t;
        pair.approve(address(m), type(uint256).max);
        token.approve(address(m), type(uint256).max);
    }

    function advanceBlock(uint8 seed) external {
        vm.roll(block.number + uint256(seed) % 4);
    }

    function changeLiquidity(bool inRange) external {
        manager.setLiquidity(inRange ? uint128(1 ether) : 0);
    }

    function swap(uint96 seed, uint8 mode, uint96 capSeed, bool exhaustRange) external {
        _trade(1 + uint256(seed) % 1e20, mode % 4, uint256(capSeed), exhaustRange);
    }

    function swapWithCashlessManager(uint96 seed, bool exhaustRange) external {
        // Model withdrawal of free manager reserves, never withdraw backing for existing claims.
        if (manager.claims() != 0) return;
        manager.drainPair(address(this));
        manager.setLiquidity(1 ether);
        _trade(10_000 + uint256(seed) % 1e20, 0, type(uint96).max, exhaustRange);
    }

    function _trade(uint256 amount, uint8 mode, uint256 capSeed, bool exhaustRange) private {
        bool pairInput = mode < 2;
        bool exactInput = mode % 2 == 0;
        uint256 donation;
        uint256 fee;
        uint256 cap;
        {
            uint256 elapsed = block.number - hook.poolOpenBlock();
            uint256 bps = elapsed < 10 ? 3000 - elapsed * 300 : 0;
            bool pairSpecified = pairInput == exactInput;
            uint256 intended = amount;
            if (pairSpecified) {
                donation = amount * bps / 10_000;
                fee = amount / 200;
                intended = exactInput ? amount - donation - fee : amount + donation + fee;
            }
            cap = capSeed % (intended + 1);
            uint256 fill = intended < cap ? intended : cap;
            if (manager.liquidity() == 0) fill = 0;
            if (pairSpecified) {
                donation = donation * fill / intended;
                fee = fee * fill / intended;
            } else {
                uint256 pairedExecution = pairInput ? (fill * 10_000 + 19_749) / 19_750 : fill * 9875 / 20_000;
                donation = pairedExecution * bps / 10_000;
                fee = pairedExecution / 200;
            }
        }
        // A modeled LP can add paired assets before a sell. This transfers, never mints.
        if (!pairInput && pair.balanceOf(address(manager)) < 1e24) {
            require(pair.transfer(address(manager), 1e24), "LP funding");
        }
        manager.setCap(cap);
        manager.setExhaustRange(exhaustRange);
        SwapParams memory params;
        params.zeroForOne = pairInput == manager.pairIs0();
        params.amountSpecified = exactInput ? -int256(amount) : int256(amount);
        params.sqrtPriceLimitX96 =
            params.zeroForOne ? uint160(4_295_128_740) : uint160(1461446703485210103287273052203988822378723970341);
        manager.trade(params);
        expectedFees += fee;
        expectedDonations += donation;
        successfulSwaps++;
    }

    function buyback(uint96 capSeed, bool rejectMinimum) external {
        uint256 reserve = hook.accumulatedPairedFees();
        uint256 cap = uint256(capSeed) % (reserve + 1);
        uint256 spent = reserve < cap ? reserve : cap;
        if (manager.liquidity() == 0) spent = 0;
        uint256 output = spent * 19_750 / 10_000;
        uint256 minimum = rejectMinimum ? output + 1 : 1;
        manager.setCap(cap);
        manager.setExhaustRange(false);
        uint256 oldPending = hook.pendingDonation();
        uint256 oldClaims = hook.pairedClaims();
        uint256 oldCash = pair.balanceOf(address(hook));
        uint256 oldDonation = manager.donated0() + manager.donated1();
        uint256 oldBurned = token.balanceOf(hook.BURN_ADDRESS());
        try hook.buybackAndBurn(minimum) returns (uint256 burned) {
            require(reserve == 0 || (spent != 0 && output >= minimum), "invalid buyback succeeded");
            require(burned == output, "buyback output mismatch");
            pairedSpent += spent;
            tokensBurned += burned;
            successfulBuybacks++;
        } catch (bytes memory reason) {
            require(reserve != 0 && (spent == 0 || output < minimum), "valid buyback reverted");
            require(
                reason.length == 4 && bytes4(reason) == SIMDTESTHook.InsufficientOutput.selector,
                "unexpected buyback error"
            );
            require(
                hook.accumulatedPairedFees() == reserve && hook.pendingDonation() == oldPending,
                "failed buyback altered reserve"
            );
            require(
                hook.pairedClaims() == oldClaims && pair.balanceOf(address(hook)) == oldCash,
                "failed buyback altered backing"
            );
            require(manager.donated0() + manager.donated1() == oldDonation, "failed buyback committed donation");
            require(token.balanceOf(hook.BURN_ADDRESS()) == oldBurned, "failed buyback burned tokens");
            rejectedBuybacks++;
        }
    }

    function unauthorizedCallback(uint96 amount) external {
        PoolKey memory k = hook.getPoolKey();
        SwapParams memory params = SwapParams(manager.pairIs0(), -int256(uint256(amount) + 1), uint160(4_295_128_740));
        (bool ok, bytes memory reason) =
            address(hook).call(abi.encodeCall(hook.beforeSwap, (address(this), k, params, bytes(""))));
        require(
            !ok && reason.length == 4 && bytes4(reason) == SIMDTESTHook.OnlyPoolManager.selector,
            "forged callback accepted"
        );
    }
}

abstract contract HookInvariantTests is HookFixture {
    HookInvariantHandler internal handler;
    address[] private targets;

    function setUp() public override {
        super.setUp();
        vm.roll(OPEN);
        handler = new HookInvariantHandler(hook, manager, pair, token);
        pair.transfer(address(handler), 1e29);
        token.transfer(address(handler), 90_000_000 ether);
        targets.push(address(handler));
    }

    // Foundry discovers this ABI, the same targeting mechanism as StdInvariant.
    function targetContracts() external view returns (address[] memory) {
        return targets;
    }

    function invariantReservesMatchIndependentFeeLedger() public view {
        _assertReserves();
        _eq(
            hook.accumulatedPairedFees() + handler.pairedSpent(), handler.expectedFees(), "buyback reserve conservation"
        );
        _eq(
            manager.donated0() + manager.donated1() + hook.pendingDonation(),
            handler.expectedDonations(),
            "donation conservation"
        );
        _eq(manager.pairIs0() ? manager.donated1() : manager.donated0(), 0, "wrong donation asset");
        require(pair.balanceOf(address(manager)) >= manager.claims(), "manager claims not cash backed");
        require(!manager.active(), "unlock remained open");
    }

    function invariantOnlyPurchasedLaunchTokensReachBurnAddress() public view {
        _eq(token.balanceOf(DEAD), handler.tokensBurned(), "burn destination / amount");
        _eq(pair.balanceOf(DEAD), 0, "paired currency at burn address");
        _eq(token.totalSupply(), 1_000_000_000 ether, "nominal supply changed");
        _eq(
            token.balanceOf(address(this)) + token.balanceOf(address(handler)) + token.balanceOf(address(manager))
                + token.balanceOf(address(hook)) + token.balanceOf(token.HACKATHON_RECIPIENT()) + token.balanceOf(DEAD),
            token.totalSupply(),
            "launch token conservation"
        );
        _eq(token.balanceOf(token.HACKATHON_RECIPIENT()), 100_000_000 ether, "hackathon allocation spent");
    }

    function invariantPairedSupplyAndImmutablePoolSurviveEverySequence() public view {
        _eq(pair.totalSupply(), 2e30, "paired supply changed");
        _eq(
            pair.balanceOf(address(this)) + pair.balanceOf(address(handler)) + pair.balanceOf(address(manager))
                + pair.balanceOf(address(hook)),
            pair.totalSupply(),
            "paired value disappeared"
        );
        require(hook.poolId() == keccak256(abi.encode(key)), "pool changed");
        _eq(hook.poolOpenBlock(), OPEN, "opening reset");
        _eq(hook.POOL_FEE(), 12_500, "LP fee changed");
        uint256 elapsed = block.number - OPEN;
        _eq(hook.antiSnipeFeeBps(), elapsed < 10 ? 3000 - 300 * elapsed : 0, "fee window reopened");
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 80
/// forge-config: default.invariant.fail-on-revert = true
contract SIMDTESTHookCurrency0InvariantTest is HookInvariantTests {}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 80
/// forge-config: default.invariant.fail-on-revert = true
contract SIMDTESTHookCurrency1InvariantTest is HookInvariantTests {
    function _pairAddress() internal pure override returns (address) {
        return address(type(uint160).max - 1);
    }
}

contract SIMDTESTTokenTest {
    HookVm private constant vm = HookVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    SIMDTEST private token;

    function setUp() public {
        token = new SIMDTEST();
    }

    function testFixedSupplyMetadataAndFactoryAllocations() public {
        require(
            keccak256(bytes(token.name())) == keccak256("SIMDTEST")
                && keccak256(bytes(token.symbol())) == keccak256("SIMDTEST"),
            "metadata"
        );
        require(token.decimals() == 18 && token.totalSupply() == 1_000_000_000 ether, "supply / decimals");
        require(token.balanceOf(address(this)) == token.totalSupply(), "not fully minted to factory");
        require(token.HACKATHON_RECIPIENT() == 0x3dD5F73dD1A4E62630fAd3909673F130aD429985, "hackathon recipient");
        require(
            token.POOL_ALLOCATION() == 800_000_000 ether && token.HACKATHON_ALLOCATION() == 100_000_000 ether,
            "allocation constants"
        );
        token.transfer(ALICE, token.POOL_ALLOCATION());
        token.transfer(token.HACKATHON_RECIPIENT(), token.HACKATHON_ALLOCATION());
        require(token.balanceOf(address(this)) == 100_000_000 ether, "factory remainder");
    }

    function testTransferFailuresAndAllowanceAccounting() public {
        vm.expectRevert(bytes("Zero recipient"));
        token.transfer(address(0), 1);
        vm.expectRevert(bytes("Insufficient balance"));
        vm.prank(ALICE);
        token.transfer(BOB, 1);
        token.approve(ALICE, 10);
        vm.prank(ALICE);
        token.transferFrom(address(this), BOB, 4);
        require(token.allowance(address(this), ALICE) == 6 && token.balanceOf(BOB) == 4, "finite allowance");
        vm.expectRevert(bytes("Insufficient allowance"));
        vm.prank(ALICE);
        token.transferFrom(address(this), BOB, 7);
        token.approve(ALICE, type(uint256).max);
        vm.prank(ALICE);
        token.transferFrom(address(this), BOB, 1);
        require(token.allowance(address(this), ALICE) == type(uint256).max, "infinite approval consumed");
        vm.prank(BOB);
        token.approve(ALICE, 100);
        vm.expectRevert(bytes("Insufficient balance"));
        vm.prank(ALICE);
        token.transferFrom(BOB, address(this), 100);
        require(token.allowance(BOB, ALICE) == 100, "failed transfer consumed allowance");
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzzTransferConservesSupplyAndAllowsZeroAndSelf(uint256 seed) public {
        uint256 supply = token.totalSupply();
        uint256 amount = seed % (supply + 1);
        token.transfer(address(this), amount);
        require(token.balanceOf(address(this)) == supply, "self transfer changed balance");
        token.transfer(ALICE, amount);
        vm.prank(ALICE);
        token.transfer(BOB, amount);
        vm.prank(BOB);
        token.transfer(address(this), amount);
        require(
            token.balanceOf(address(this)) == supply && token.balanceOf(ALICE) == 0 && token.balanceOf(BOB) == 0,
            "round trip changed balances"
        );
        require(token.totalSupply() == supply, "transfer changed supply");
    }
}
