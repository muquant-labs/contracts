// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract Vault {
    mapping(address => bool) public keeper;
    mapping(address => bool) public mkeeper;
    address public Guard;
    struct Wall {
        address stable;
        uint256 amount;
    }

    mapping (address => Wall) public vaults;
    constructor(address[] memory keepers, address guard) {
        Guard = guard;
        for (uint256 i = 0; i < keepers.length; i++) {
            keeper[keepers[i]] = true;
            mkeeper[keepers[i]] = true;
        }
    }

    function deposit(address token, address stable, uint256 amount) external {
        require(keeper[msg.sender], "Vault: not keeper");
        if (vaults[token].stable == address(0)) {
            vaults[token].stable = stable;
        }
        vaults[token].amount += amount;
    }

    function withdraw(address token, address to, uint256 amount) external {
        require(keeper[msg.sender], "Vault: not keeper");
        require(vaults[token].amount >= amount, "Vault: not enough");
        require(vaults[token].stable != address(0), "Vault: not exist");
        vaults[token].amount -= amount;
        SafeERC20.safeTransfer(IERC20(vaults[token].stable), to, amount);
    }

    function getVault(address token) external view returns (address, uint256) {
        return (vaults[token].stable, vaults[token].amount);
    }

    function safe(address _keeper) external {
        require(msg.sender == Guard, "Vault: not guard");
        require(mkeeper[_keeper], "Vault: not keeper");
        keeper[_keeper] = !keeper[_keeper];
    }
}
