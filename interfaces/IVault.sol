// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

interface IVault {
    function deposit(address token, address stable, uint256 amount) external;
    function withdraw(address token, address to, uint256 amount) external;
    function getVault(address token) external view returns (address, uint256);
}
