// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import '@uniswap/v3-periphery/contracts/base/PeripheryImmutableState.sol';
import '@uniswap/v3-core/contracts/libraries/SafeCast.sol';
import '@uniswap/v3-core/contracts/libraries/TickMath.sol';
import '@uniswap/v3-core/contracts/libraries/TickBitmap.sol';
import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol';
import '@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol';
import '@uniswap/v3-periphery/contracts/libraries/PoolAddress.sol';
import '@uniswap/v3-periphery/contracts/libraries/CallbackValidation.sol';
import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol';

import '../interfaces/IQuoterV3.sol';
import '../libraries/PoolTicksCounter.sol';
import '../libraries/UniswapV2Library.sol';
import '../libraries/Path.sol';

import 'hardhat/console.sol';

/// @title Provides quotes for swaps
/// @notice Allows getting the expected amount out or amount in for a given swap without executing the swap
/// @dev These functions are not gas efficient and should _not_ be called on chain. Instead, optimistically execute
/// the swap and check the amounts in the callback.
contract QuoterV3 is IQuoterV3, IUniswapV3SwapCallback, PeripheryImmutableState {
    using Path for bytes;
    using SafeCast for uint256;
    using PoolTicksCounter for IUniswapV3Pool;
    address public v2Factory;

    /// @dev Transient storage variable used to check a safety condition in exact output swaps.
    uint256 private amountOutCached;

    constructor(
        address _factory,
        address _v2Factory,
        address _WETH9
    ) PeripheryImmutableState(_factory, _WETH9) {
        v2Factory = _v2Factory;
    }

    function getPool(
        address tokenA,
        address tokenB,
        uint24 fee
    ) private view returns (IUniswapV3Pool) {
        return IUniswapV3Pool(PoolAddress.computeAddress(factory, PoolAddress.getPoolKey(tokenA, tokenB, fee)));
    }

    function getPair(address tokenA, address tokenB) external view returns (address pair) {
        return UniswapV2Library.pairFor(v2Factory, tokenA, tokenB);
    }

    // @note used for exactIn
    function getPairAmountOut(
        uint256 amountIn,
        address tokenA,
        address tokenB
    ) external view returns (uint256) {
        // reserveA & reserveB == reserveIn & reserveOut
        (uint256 reserveA, uint256 reserveB) = UniswapV2Library.getReserves(v2Factory, tokenA, tokenB);
        return UniswapV2Library.getAmountOut(amountIn, reserveA, reserveB);
    }

    /// @inheritdoc IUniswapV3SwapCallback
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes memory path
    ) external view override {
        require(amount0Delta > 0 || amount1Delta > 0); // swaps entirely within 0-liquidity regions are not supported
        (address tokenIn, address tokenOut, uint24 fee) = path.decodeFirstPool();
        CallbackValidation.verifyCallback(factory, tokenIn, tokenOut, fee);

        (bool isExactInput, uint256 amountToPay, uint256 amountReceived) =
            amount0Delta > 0
                ? (tokenIn < tokenOut, uint256(amount0Delta), uint256(-amount1Delta))
                : (tokenOut < tokenIn, uint256(amount1Delta), uint256(-amount0Delta));

        IUniswapV3Pool pool = getPool(tokenIn, tokenOut, fee);
        (uint160 sqrtPriceX96After, int24 tickAfter, , , , , ) = pool.slot0();

        if (isExactInput) {
            assembly {
                let ptr := mload(0x40)
                mstore(ptr, amountReceived)
                mstore(add(ptr, 0x20), sqrtPriceX96After)
                mstore(add(ptr, 0x40), tickAfter)
                revert(ptr, 96)
            }
        } else {
            // if the cache has been populated, ensure that the full output amount has been received
            if (amountOutCached != 0) require(amountReceived == amountOutCached);
            assembly {
                let ptr := mload(0x40)
                mstore(ptr, amountToPay)
                mstore(add(ptr, 0x20), sqrtPriceX96After)
                mstore(add(ptr, 0x40), tickAfter)
                revert(ptr, 96)
            }
        }
    }

    /// @dev Parses a revert reason that should contain the numeric quote
    function parseRevertReason(bytes memory reason)
        private
        pure
        returns (
            uint256 amount,
            uint160 sqrtPriceX96After,
            int24 tickAfter
        )
    {
        if (reason.length != 96) {
            if (reason.length < 68) revert('Unexpected error');
            assembly {
                reason := add(reason, 0x04)
            }
            revert(abi.decode(reason, (string)));
        }
        return abi.decode(reason, (uint256, uint160, int24));
    }

    function handleRevert(
        bytes memory reason,
        IUniswapV3Pool pool,
        uint256 gasEstimate
    )
        private
        view
        returns (
            uint256 amount,
            uint160 sqrtPriceX96After,
            uint32 initializedTicksCrossed,
            uint256
        )
    {
        int24 tickBefore;
        int24 tickAfter;
        (, tickBefore, , , , , ) = pool.slot0();
        (amount, sqrtPriceX96After, tickAfter) = parseRevertReason(reason);

        initializedTicksCrossed = pool.countInitializedTicksCrossed(tickBefore, tickAfter);

        return (amount, sqrtPriceX96After, initializedTicksCrossed, gasEstimate);
    }

    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        public
        override
        returns (
            uint256 amountOut,
            uint160 sqrtPriceX96After,
            uint32 initializedTicksCrossed,
            uint256 gasEstimate
        )
    {
        bool zeroForOne = params.tokenIn < params.tokenOut;
        IUniswapV3Pool pool = getPool(params.tokenIn, params.tokenOut, params.fee);

        uint256 gasBefore = gasleft();
        try
            pool.swap(
                address(this), // address(0) might cause issues with some tokens
                zeroForOne,
                params.amountIn.toInt256(),
                params.sqrtPriceLimitX96 == 0
                    ? (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1)
                    : params.sqrtPriceLimitX96,
                abi.encodePacked(params.tokenIn, params.fee, params.tokenOut)
            )
        {} catch (bytes memory reason) {
            gasEstimate = gasBefore - gasleft();
            return handleRevert(reason, pool, gasEstimate);
        }
    }

    function quoteExactInputSingleV2(
        uint256 amountIn,
        address tokenIn,
        address tokenOut
    ) public view returns (uint256 amountOut, uint256 gasEstimate) {
        uint256 gasBefore = gasleft();
        amountOut = this.getPairAmountOut(amountIn, tokenIn, tokenOut);
        return (amountOut, gasBefore - gasleft());
    }

    /**
        Path notes:
        - a V3 pool is encoded as:
        ___first pair___(20 bytes) + ___fee___(3 bytes) + ___second token___(20 bytes)

        Approach for IL:
        - We pass in a separate bytes array for the Protcols that each pool belongs to, where each index corresponds
          to a pool or pair in the path array since intermediary tokens are not repeated. Ex:

        (USDC fee [WETH) fee DAI], PF array: [1 (USDC-WETH as a V3 pool), 0 (WETH-DAI as a V2 pair)]

        0 for V2, 1 for V3
     */
    function quoteExactInput(
        bytes memory path,
        bytes memory protocolFlags,
        uint256 amountIn
    )
        public
        returns (
            uint256 amountOut,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksCrossedList,
            uint256 gasEstimate
        )
    {
        sqrtPriceX96AfterList = new uint160[](path.numPools()); // @note init list of the pool prices, in X96 format
        initializedTicksCrossedList = new uint32[](path.numPools());

        // @dev path and protocol flags must be the same length
        require(path.numPools() == protocolFlags.length, 'Length mismatch');

        uint256 i = 0; // @note that i = the current pool index
        while (true) {
            (address tokenIn, address tokenOut, uint24 fee) = path.decodeFirstPool();
            // @note I think we can use the Path library for this PF array too: consume with .toUint8() and .slice(1,1) to move forward

            // @note we are 1 var away from stack to deep LOL
            if (protocolFlags.decodeFirstProtocolFlag() == 0) {
                // V2
                (uint256 _amountOut, uint256 _gasEstimate) = quoteExactInputSingleV2(amountIn, tokenIn, tokenOut);
                gasEstimate += _gasEstimate;
                amountIn = _amountOut;
            } else {
                // the outputs of prior swaps become the inputs to subsequent ones
                (
                    uint256 _amountOut,
                    uint160 _sqrtPriceX96After,
                    uint32 _initializedTicksCrossed,
                    uint256 _gasEstimate
                ) =
                    quoteExactInputSingle(
                        QuoteExactInputSingleParams({
                            tokenIn: tokenIn, // @note pool-specific values that are different for each interation but not reassigned
                            tokenOut: tokenOut,
                            fee: fee,
                            amountIn: amountIn,
                            sqrtPriceLimitX96: 0 // @note looks like we can't specify a limit
                        })
                    );

                sqrtPriceX96AfterList[i] = _sqrtPriceX96After;
                initializedTicksCrossedList[i] = _initializedTicksCrossed;
                gasEstimate += _gasEstimate;
                amountIn = _amountOut; // @note assigning output of this swap to input for next
            }
            i++;

            // decide whether to continue or terminate
            if (path.hasMultiplePools()) {
                path = path.skipToken(); // @note move pointer forward, changing path in place so .decodeFirstPool pulls the next pool
                protocolFlags = protocolFlags.skipProtocolFlag();
            } else {
                // @note amountIn will be the final output of the last swap in route
                return (amountIn, sqrtPriceX96AfterList, initializedTicksCrossedList, gasEstimate);
            }
        }
    }

    /**
        ORIGINAL:
     */
    function quoteExactInput(bytes memory path, uint256 amountIn)
        public
        override
        returns (
            uint256 amountOut,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksCrossedList,
            uint256 gasEstimate
        )
    {
        sqrtPriceX96AfterList = new uint160[](path.numPools());
        initializedTicksCrossedList = new uint32[](path.numPools());

        uint256 i = 0;
        while (true) {
            (address tokenIn, address tokenOut, uint24 fee) = path.decodeFirstPool();

            // the outputs of prior swaps become the inputs to subsequent ones
            (uint256 _amountOut, uint160 _sqrtPriceX96After, uint32 _initializedTicksCrossed, uint256 _gasEstimate) =
                quoteExactInputSingle(
                    QuoteExactInputSingleParams({
                        tokenIn: tokenIn,
                        tokenOut: tokenOut,
                        fee: fee,
                        amountIn: amountIn,
                        sqrtPriceLimitX96: 0
                    })
                );

            sqrtPriceX96AfterList[i] = _sqrtPriceX96After;
            initializedTicksCrossedList[i] = _initializedTicksCrossed;
            amountIn = _amountOut;
            gasEstimate += _gasEstimate;
            i++;

            // decide whether to continue or terminate
            if (path.hasMultiplePools()) {
                path = path.skipToken();
            } else {
                return (amountIn, sqrtPriceX96AfterList, initializedTicksCrossedList, gasEstimate);
            }
        }
    }
}