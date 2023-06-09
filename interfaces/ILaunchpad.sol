// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

interface ILaunchpad {
    struct Pair {
        address stable;
        uint256 liquidity;
        uint256 base;
        uint256 quote;
        uint256 fees;
        uint256[3] rates;
        address sponsored;
    }

    struct Limit {
        uint256 startTime;
        uint256 minVotes;
        uint256 limitBySupply;
        uint256 limitByBalance;
        uint256 taxOverLimit;
        uint256 frequency;
        uint256 maxByOwner;
    }

    struct Agent {
        address creator;
        uint256 timestamp;
        bool approval;
        uint256 votes;
    }

    function enableSwap(address token) external view returns (bool);

    function getPair(address token) external view returns (Pair memory);

    function getLimit(address token) external view returns (Limit memory);

    function getAgent(address token) external view returns (Agent memory);

    function getReserves(
        address token
    ) external view returns (uint256, uint256, uint256);

    function checkOwned(
        address _sender,
        address _token,
        uint256 _amount
    ) external view returns (bool);

    function increaseOwned(
        address _sender,
        address _token,
        uint256 _amount
    ) external;

    function checkLimitBySupply(
        address _token,
        uint256 _amount
    ) external view returns (bool);

    function getTax(
        address _sender,
        address _token,
        uint256 _amountIn,
        uint256 _amountOut
    ) external view returns (uint256 tax);

    function checkFrequency(
        address _sender,
        address _token
    ) external view returns (bool);

    function setFrequency(address _sender, address _token) external;

    function checkStable(address _token) external view returns (bool);

    function sync(address _token) external;

    function reserves(
        address[2] memory _path,
        uint256[2] memory _amounts
    ) external returns (bool);

    function getCreator(address _token) external view returns (address);

    function getStable(address _token) external view returns (address);

    function getStableList() external view returns (address[] memory);

    function Tokens() external view returns (uint256);
    function Original() external view returns (address);
}
