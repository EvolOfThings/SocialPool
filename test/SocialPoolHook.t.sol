// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {console} from "forge-std/console.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

import {SocialPoolHook} from "../src/SocialPoolHook.sol";
import {SocialAVSMock} from "../test/mocks/SocialAVSMock.sol";

contract TestSocialPoolHook is Test, Deployers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    SocialPoolHook hook;
    SocialAVSMock socialAvs;
    Currency socialToken;

    function deploySocialAVS() internal {
        socialAvs = new SocialAVSMock();
    }

    function deploySocialToken() internal {
        MockERC20 mock = new MockERC20("Social Token", "SOCIAL", 18);
        socialToken = Currency.wrap(address(mock));
    }

    function setUp() public {
        // Deploy v4-core
        deployFreshManagerAndRouters();
        deploySocialAVS();
        // Deploy, mint tokens, and approve all periphery contracts for two tokens
        deployMintAndApprove2Currencies();

        // Deploy our hook with the proper flags
        address hookAddress = address(uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG));

        // Set gas price = 10 gwei and deploy our hook
        vm.txGasPrice(10 gwei);
        deployCodeTo("SocialPoolHook.sol", abi.encode(manager, socialAvs, socialToken, socialToken), hookAddress);
        hook = SocialPoolHook(hookAddress);

        // Initialize a pool
        (key,) = initPool(
            currency0,
            socialToken,
            hook,
            LPFeeLibrary.DYNAMIC_FEE_FLAG, // Set the `DYNAMIC_FEE_FLAG` in place of specifying a fixed fee
            SQRT_PRICE_1_1
        );

        // Add some liquidity
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 100 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    function test_simulateAddingAdditionalLiquidity_On_Increasing_SocialDominance() public {
        // Set up our swap parameters
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -0.00001 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        int8 currentSocialDominance = socialAvs.getSignal(uint64(block.number), uint64(block.number + 133));
        uint256 firstCallBlockNumber = block.number;
        vm.roll(block.number + 133);
        // ----------------------------------------------------------------------
        // ----------------------------------------------------------------------
        // ----------------------------------------------------------------------
        // ----------------------------------------------------------------------
        int8 newSocialDominance = socialAvs.getSignal(uint64(firstCallBlockNumber), uint64(block.number + 133));
        assertGt(newSocialDominance, currentSocialDominance);

        // 1. Conduct a swap to simulate volume
        uint256 balanceOfToken1Before = socialToken.balanceOfSelf();
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        uint256 balanceOfToken1After = socialToken.balanceOfSelf();
        uint256 outputFromBaseFeeSwap = balanceOfToken1After - balanceOfToken1Before;

        assertGt(balanceOfToken1After, balanceOfToken1Before);

        // ----------------------------------------------------------------------
        // ----------------------------------------------------------------------
        // ----------------------------------------------------------------------
        // ----------------------------------------------------------------------

        // 2. Conduct a second swap
        vm.txGasPrice(4 gwei);
        balanceOfToken1Before = socialToken.balanceOfSelf();
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        balanceOfToken1After = socialToken.balanceOfSelf();

        uint256 outputFromIncreasedFeeSwap = balanceOfToken1After - balanceOfToken1Before;

        assertGt(balanceOfToken1After, balanceOfToken1Before);

        // 3. Conduct a third swap
        vm.txGasPrice(12 gwei);
        balanceOfToken1Before = socialToken.balanceOfSelf();
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        balanceOfToken1After = socialToken.balanceOfSelf();

        uint256 outputFromDecreasedFeeSwap = balanceOfToken1After - balanceOfToken1Before;

        assertGt(balanceOfToken1After, balanceOfToken1Before);

        // 4. Add liquidity after simulating volume

        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 1000 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );

        // Check if additional liquidity was added
        vm.expectEmit(address(hook));
        assertGt(hook.userPositions(address(this)), 0);

        // ------

        // 4. Check all the output amounts

        console.log("Base Fee Output", outputFromBaseFeeSwap);
        console.log("Increased Fee Output", outputFromIncreasedFeeSwap);
        console.log("Decreased Fee Output", outputFromDecreasedFeeSwap);

        assertGt(outputFromDecreasedFeeSwap, outputFromBaseFeeSwap);
        assertGt(outputFromBaseFeeSwap, outputFromIncreasedFeeSwap);
    }
}
