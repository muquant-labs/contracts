// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

interface IRouter {
    function swapExactStableForToken(
        address ref,
        uint256 amountIn,
        uint256 amountOutMin,
        address token,
        address to,
        uint256 deadline
    ) external returns (uint256 amountOut);

    function swapExactTokenForStable(
        address ref,
        uint256 amountIn,
        uint256 amountOutMin,
        address token,
        address to,
        uint256 deadline
    ) external returns (uint256 amountOut);

    function swapStableForExactToken(
        address ref,
        uint256 amountOut,
        uint256 amountInMax,
        address token,
        address to,
        uint256 deadline
    ) external returns (uint256 amountIn);

    function swapTokenForExactStable(
        address ref,
        uint256 amountOut,
        uint256 amountInMax,
        address token,
        address to,
        uint256 deadline
    ) external returns (uint256 amountIn);
}
