// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

library MuLibrary {
    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut,
        uint256 fees
    ) internal pure returns (uint256 amountOut) {
        require(amountIn > 0, "MuLibrary: INSUFFICIENT_INPUT_AMOUNT");
        require(
            reserveIn > 0 && reserveOut > 0,
            "MuLibrary: INSUFFICIENT_LIQUIDITY"
        );
        uint256 amountInWithFee = amountIn * (10000 - fees);
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 10000 + amountInWithFee;
        amountOut = numerator / denominator;
    }

    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut,
        uint256 fees
    ) internal pure returns (uint256 amountIn) {
        require(amountOut > 0, "MuLibrary: INSUFFICIENT_OUTPUT_AMOUNT");
        require(
            reserveIn > 0 && reserveOut > 0,
            "MuLibrary: INSUFFICIENT_LIQUIDITY"
        );
        uint256 numerator = reserveIn * amountOut * 10000;
        uint256 denominator = (reserveOut - amountOut) * (10000 - fees);
        amountIn = numerator / denominator + 1;
    }

    function calcRange(
        uint256 amount,
        uint256[] memory range
    ) internal pure returns (uint256 rg) {
        for (uint256 i = 0; i < range.length; i++) {
            if (amount >= range[i]) {
                rg++;
            } else {
                return rg;
            }
        }
    }
}
