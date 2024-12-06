// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/contracts/types/Currency.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";

// Interface for IEigenLayerAVS social signal contract
interface IEigenLayerAVS {
    function getSignal(
        uint64 blockFrom,
        uint64 blockTo
    ) external view returns (int8 interestDelta);
}

contract SocialPoolHook is BaseHook {
    using PoolIdLibrary for PoolKey;

    IEigenLayerAVS public avs;
    IERC20 public socialToken;
    Currency public immutable pairedToken;  // The token paired with social token (e.g., WETH)
    PoolId public socialTokenPoolId; 

    // Define tick range and sentiment thresholds
    int24 public lowerTick;
    int24 public upperTick;

    //threshold for interestDelta
    int256 public constant POSITIVE_THRESHOLD = 2;
    int256 public constant NEGATIVE_THRESHOLD = -2;



    // for volume tracking
    uint256 public constant VOLUME_BLOCK_RANGE = 20; // Look back 20 blocks for volume trend
    // for volume tracking per token
    mapping(address => mapping(uint256 => uint256)) public tokenBlockVolume;  // token => block number => volume
    mapping(address => uint256) public lastTokenVolumeAverage;  // token => last average volume
    mapping(address => uint256) public lastTokenUpdateBlock;    // token => last update block number





     // Position adjustment thresholds
    uint256 public constant MIN_VOLUME_CHANGE_THRESHOLD = 5;  // 5% minimum volume change to consider
    uint256 public constant POSITION_ADJUST_PERCENT = 10;     // 10% position adjustment
    


    // Position tracking
    mapping(address => uint256) public userPositions;
    uint256 public totalLiquidity;


    // Events
    event SwapExecuted(address indexed sender, uint256 amountIn, uint256 amountOut, int256 sentiment, uint256 volumeChange);
    event LiquidityAdjusted(address indexed provider, int256 delta, int256 sentiment, uint256 volumeChange);
    event PositionUpdated(address indexed user, uint256 newPosition, int256 sentiment, uint256 volumeChange);
    event TickRangeUpdated(int24 newLowerTick, int24 newUpperTick, int256 sentiment);
    
  

    constructor(
        IPoolManager _poolManager, 
        IEigenLayerAVS _avs, 
        IERC20 _socialToken,
        Currency _pairedToken
    ) BaseHook(_poolManager) {
        avs = _avs;
        socialToken = _socialToken;
        pairedToken = _pairedToken;

         // We need to initialize pool ID for the social token pair
        socialTokenPoolId = PoolId.wrap(
            keccak256(
                abi.encode(
                    Currency.wrap(address(socialToken)),
                    pairedToken,
                    3000 // 0.3% fee tier
                )
            )
        );

        // Initialize with maximum tick range
        lowerTick = -887272;
        upperTick = 887272;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeModifyPosition: true,
            afterModifyPosition: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // -----------------------------------------------
    // NOTE: see IHooks.sol for function documentation
    // -----------------------------------------------



     /**
     * Fetches current social sentiment from AVS
     * return sentiment Current social sentiment score
     */
    function getCurrentSentiment() public view returns (int256) {
        // uint64 blockFrom = uint64(block.number - 100);
        // uint64 blockTo = uint64(block.number);
        // return avs.getSignal(blockFrom, blockTo);
    }

    /**
     * Get average volume for a specific token over the last n blocks
     * token The token address to get volume for
     * blocks Number of blocks to look back
     */
       function getAverageVolume(address token, uint256 blocks) public view returns (uint256) {
        uint256 totalVolume = 0;
        uint256 count = 0;
        uint256 currentBlock = block.number;
        
        for (uint256 i = 0; i < blocks && i <= currentBlock; i++) {
            uint256 volume = tokenBlockVolume[token][currentBlock - i];
            if (volume > 0) {
                totalVolume += volume;
                count++;
            }
        }
        
        return count > 0 ? totalVolume / count : 0;
    }

    /**
     * Get the volume trend for a specific token over the specified block range
     *  trend Percentage change in volume (-100 to +100)
     */
    function getVolumeTrend(address token) public view returns (int256) {
        uint256 currentAverage = getAverageVolume(token, VOLUME_BLOCK_RANGE);
        if (lastTokenVolumeAverage[token] == 0) return 0;
        
        int256 change = int256(currentAverage) - int256(lastTokenVolumeAverage[token]);
        return (change * 100) / int256(lastTokenVolumeAverage[token]);
    }



    /**
     * Determines if liquidity should be adjusted based on interestDelta and volume
     * it returns shouldAdjust, whether position should be adjustedm and 
     * also returns adjustmentAmount, amount to adjust (positive for increase, negative for decrease)
     */
    function calculateLiquidityAdjustment(
        int256 interestDelta,
        int256 volumeTrend
    ) internal view returns (bool shouldAdjust, int256 adjustmentAmount) {
        // Case 1: Positive interest delta and increasing volume
        if (interestDelta > 0 && volumeTrend > int256(MIN_VOLUME_CHANGE_THRESHOLD)) {
            // Calculate increase amount based on both metrics
            uint256 baseAdjustment = (userPositions[msg.sender] * POSITION_ADJUST_PERCENT) / 100;
            
            // Increase LP if both signals are positive
            if (interestDelta > POSITIVE_THRESHOLD && volumeTrend > 20) {
                baseAdjustment = (baseAdjustment * 3) / 2; // 50% bonus
            }
            
            return (true, int256(baseAdjustment));
        }
        
        // Case 2: Negative interest delta and decreasing volume
        if (interestDelta < 0 && volumeTrend < -int256(MIN_VOLUME_CHANGE_THRESHOLD)) {
            // Calculate decrease amount based on both metrics
            uint256 baseAdjustment = (userPositions[msg.sender] * POSITION_ADJUST_PERCENT) / 100;
            
            // Withdrawal if both signals are strongly negative
            if (interestDelta < NEGATIVE_THRESHOLD && volumeTrend < -20) {
                baseAdjustment = (baseAdjustment * 3) / 2; // 50% increase in withdrawal
            }
            
            return (true, -int256(baseAdjustment));
        }
        
        return (false, 0);
    }

  /**
     * Adjusts tick range based on social sentiment
     * When sentiment is positive, widen the range to allow for more price movement
     * When sentiment is negative, narrow the range to concentrate liquidity

     */
    function adjustTickRange(int256 sentiment) internal {
        int24 newLowerTick = lowerTick;
        int24 newUpperTick = upperTick;

        if (sentiment >= POSITIVE_THRESHOLD) {
            // Widen the range for positive sentiment
            newLowerTick = -887272; // Max tick range
            newUpperTick = 887272;
        } else if (sentiment <= NEGATIVE_THRESHOLD) {
            // Narrow the range for negative sentiment
            newLowerTick = -443636; // Half of max tick range
            newUpperTick = 443636;
        } else {
            // For neutral sentiment, use 75% of max range
            newLowerTick = -665454;
            newUpperTick = 665454;
        }

        if (newLowerTick != lowerTick || newUpperTick != upperTick) {
            lowerTick = newLowerTick;
            upperTick = newUpperTick;
            emit TickRangeUpdated(newLowerTick, newUpperTick, sentiment);
        }
    }



    /**
     * Getting the current pool data for social token pair
     * returns sqrtPriceX96, current tick, current liquidity
     */
    function getSocialTokenPoolData() public view returns (
        uint160 sqrtPriceX96,
        int24 tick,
        uint128 liquidity
    ) {
        (sqrtPriceX96, tick, , , , , ) = poolManager.getSlot0(socialTokenPoolId);
        liquidity = poolManager.getLiquidity(socialTokenPoolId);
        return (sqrtPriceX96, tick, liquidity);
    }

    /**
     * @dev Validate that the operation is for the social token pool
     */
    function validateSocialTokenPool(PoolKey calldata key) internal view {
        require(
            (Currency.unwrap(key.currency0) == address(socialToken) && key.currency1 == pairedToken) ||
            (Currency.unwrap(key.currency1) == address(socialToken) && key.currency0 == pairedToken),
            "Not social token pool"
        );
    }


    /**
     * Core feature: Hook called before modifying a position (adding or removing liquidity)
     */
    function beforeModifyPosition(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata
    ) external override returns (bytes4) {
        // Making sure we're using the social token pool
        validateSocialTokenPool(key);

        int256 interestDelta = getCurrentSentiment();
        int256 volumeTrend = getVolumeTrend();

        // Get current pool data
        (uint160 sqrtPriceX96, int24 currentTick, ) = getSocialTokenPoolData();
        
        // Adjusting the tick range based on sentiment
        adjustTickRange(interestDelta);
        
        // Making sure the position is within the adjusted tick range
        require(
            params.tickLower >= lowerTick && params.tickUpper <= upperTick,
            "Position outside adjusted tick range"
        );

        // If adding liquidity
        if (params.liquidityDelta > 0) {
            // Checking if sentiment is positive and volume is increasing
            if (interestDelta > 0 && volumeTrend > 0) {
                // Increase the LP
                uint256 baseAdjustment = uint256(params.liquidityDelta) * 10 / 100; // 10% increase
                
                // If both signals are strongly positive, increase even more LP
                if (interestDelta > POSITIVE_THRESHOLD && volumeTrend > 20) {
                    baseAdjustment = baseAdjustment * 3 / 2; // 15% total increase
                }
                
                params.liquidityDelta += int256(baseAdjustment);
            }
        }
        // If removing liquidity 
        else if (params.liquidityDelta < 0) {
            // Checking if sentiment is negative and volume is decreasing
            if (interestDelta < 0 && volumeTrend < 0) {
                // Increase the withdrawal amount
                uint256 baseAdjustment = uint256(-params.liquidityDelta) * 10 / 100; // 10% increase
                
                // If both signals are strongly negative, increase withdrawal further more
                if (interestDelta < NEGATIVE_THRESHOLD && volumeTrend < -20) {
                    baseAdjustment = baseAdjustment * 3 / 2; // 15% total increase
                }
                
                params.liquidityDelta -= int256(baseAdjustment);
            }
        }

        // Update position tracking
        if (params.liquidityDelta > 0) {
            userPositions[sender] += uint256(params.liquidityDelta);
            totalLiquidity += uint256(params.liquidityDelta);
        } else {
            userPositions[sender] -= uint256(-params.liquidityDelta);
            totalLiquidity -= uint256(-params.liquidityDelta);
        }

        emit LiquidityAdjusted(sender, params.liquidityDelta, interestDelta, uint256(volumeTrend));
        emit PositionUpdated(sender, userPositions[sender], interestDelta, uint256(volumeTrend));

        return BaseHook.beforeModifyPosition.selector;
    }

    /**
     * Hook called after a swap to track volume
     */
    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta
    ) external override returns (bytes4) {
        // Update volume
        uint256 volume = uint256(params.amountSpecified > 0 ? params.amountSpecified : -params.amountSpecified);
        blockVolume[block.number] = volume;
        
        // Update volume average for every VOLUME_BLOCK_RANGE blocks
        if (block.number >= lastUpdateBlock + VOLUME_BLOCK_RANGE) {
            lastVolumeAverage = getAverageVolume(VOLUME_BLOCK_RANGE);
            lastUpdateBlock = block.number;
        }
        
        emit SwapExecuted(
            sender,
            uint256(params.amountSpecified > 0 ? params.amountSpecified : 0),
            uint256(params.amountSpecified < 0 ? -params.amountSpecified : 0),
            getCurrentSentiment(),
            uint256(getVolumeTrend())
        );
        
        return BaseHook.afterSwap.selector;
    }

    /**
     * Calculating average volume over last N blocks
     */
    function getAverageVolume(uint256 blockRange) public view returns (uint256) {
        uint256 totalVolume = 0;
        uint256 count = 0;
        
        for (uint256 i = block.number; i > block.number - blockRange && i > 0; i--) {
            if (blockVolume[i] > 0) {
                totalVolume += blockVolume[i];
                count++;
            }
        }
        
        return count > 0 ? totalVolume / count : 0;
    }
}



// We need following for deploying:

// The social token address
// The paired token (like WETH)
// The EigenLayer AVS address
// The pool manager address