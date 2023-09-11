// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "./interfaces/IAffiliate.sol";
import "./interfaces/IVault.sol";
import "./interfaces/ILaunchpad.sol";
import "./interfaces/IRouter.sol";
import "./libraries/MuLibrary.sol";

contract Lock is Initializable, AccessControlUpgradeable, UUPSUpgradeable {
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant LAUNCHPAD_ROLE = keccak256("LAUNCHPAD_ROLE");
    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");
    bytes32 public constant ROUTER_ROLE = keccak256("ROUTER_ROLE");

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize() public initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(UPGRADER_ROLE, msg.sender);
        _setRoleAdmin(UPGRADER_ROLE, UPGRADER_ROLE);
        _grantRole(LAUNCHPAD_ROLE, msg.sender);
        _setRoleAdmin(LAUNCHPAD_ROLE, LAUNCHPAD_ROLE);
        _grantRole(VAULT_ROLE, msg.sender);
        _setRoleAdmin(VAULT_ROLE, VAULT_ROLE);
        _grantRole(ROUTER_ROLE, msg.sender);
        _setRoleAdmin(ROUTER_ROLE, ROUTER_ROLE);
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(UPGRADER_ROLE) {}

    address public Vault;
    IVault public vault;
    address public Router;
    IRouter public router;
    uint256 public constant DENTIME = 10 ** 19;
    uint256 public constant DENOMINATOR = 10000;
    ILaunchpad public launchpad;
    struct Config {
        address lockToken;
        uint256 startTime;
        uint256[] range;
        uint256[] apr;
        uint256[] lockTime;
        uint256 dustTime;
        uint256[] maxReward;
        uint256[] vesting;
        address receiveToken;
        address affiliate;
        uint256 usageRate;
        address usageAddr;
    }

    struct Timeline {
        uint256 amount;
        uint256 start;
        uint256 end;
        uint256 endVest;
        uint256 recent;
        uint8 status;
    }

    struct Box {
        uint256 recentTime;
        uint256 amounts;
        uint256 received;
        uint256[] map;
        uint256 tick;
    }

    mapping(address => Config) public configs;
    mapping(address => mapping(address => Box)) public boxs;
    mapping(address => mapping(address => mapping(uint256 => Timeline)))
        public timelines;
    uint256 public Lockers;
    uint256 public Receiveds;

    modifier onlyCreator(address token) {
        require(msg.sender == launchpad.getCreator(token), "Lock: creator");
        _;
    }

    modifier started(address token) {
        require(
            block.timestamp >= configs[token].startTime &&
                configs[token].startTime > 0,
            "Lock: startTime"
        );
        _;
    }

    function setLaunchpad(
        address _launchpad
    ) external onlyRole(LAUNCHPAD_ROLE) {
        launchpad = ILaunchpad(_launchpad);
    }

    function setVault(address _vault) external onlyRole(VAULT_ROLE) {
        Vault = _vault;
        vault = IVault(_vault);
    }

    function setRouter(address _router) external onlyRole(ROUTER_ROLE) {
        Router = _router;
        router = IRouter(_router);
        address[] memory stables = launchpad.getStableList();
        for (uint256 i = 0; i < stables.length; i++) {
            SafeERC20Upgradeable.safeApprove(
                IERC20Upgradeable(stables[i]),
                _router,
                type(uint256).max
            );
        }
    }

    function setConfig(
        address token,
        uint256 startTime,
        uint256[] memory range,
        uint256[] memory apr,
        uint256[] memory lockTime,
        uint256 dustTime,
        uint256[] memory maxReward,
        uint256[] memory vesting,
        bool stable,
        address affiliate,
        uint256 usageRate,
        address usageAddr
    ) public virtual onlyCreator(token) {
        require(
            apr.length == lockTime.length &&
                lockTime.length == maxReward.length &&
                maxReward.length == vesting.length,
            "Lock: length"
        );
        require(range.length == apr.length + 1, "Lock: range");
        require(launchpad.enableSwap(token), "Lock: enableSwap");
        require(usageRate <= DENOMINATOR, "Lock: usageRate");
        require(
            usageAddr != address(0) && usageAddr != address(this),
            "Lock: usageAddr"
        );
        require(launchpad.getStable(token) != address(0), "Lock: stable");
        require(
            configs[token].startTime == 0 ||
                configs[token].startTime > block.timestamp,
            "Lock: config"
        );
        require(startTime >= block.timestamp, "Lock: startTime");
        configs[token] = Config(
            launchpad.getStable(token),
            startTime,
            range,
            apr,
            lockTime,
            dustTime,
            maxReward,
            vesting,
            stable ? launchpad.getStable(token) : token,
            affiliate,
            usageRate,
            usageAddr
        );
    }

    function modifyAffiliate(
        address token,
        address affiliate
    ) public virtual onlyCreator(token) {
        configs[token].affiliate = affiliate;
    }

    function modifyUsage(
        address token,
        uint256 usageRate,
        address usageAddr
    ) public virtual onlyCreator(token) {
        require(usageRate <= DENOMINATOR, "Lock: usageRate");
        require(
            usageAddr != address(0) && usageAddr != address(this),
            "Lock: usageAddr"
        );
        configs[token].usageRate = usageRate;
        configs[token].usageAddr = usageAddr;
    }

    function getApr(
        address locker,
        address token
    ) public virtual view returns (uint256) {
        uint256 rg = MuLibrary.calcRange(
            boxs[locker][token].amounts,
            configs[token].range
        );
        if (rg == 0) {
            return 0;
        }
        return configs[token].apr[rg - 1];
    }

    function getEnd(
        address token,
        uint256 amount
    ) public virtual view returns (uint256) {
        uint256 rg = MuLibrary.calcRange(amount, configs[token].range);
        if (rg == 0) {
            return configs[token].dustTime;
        }
        return configs[token].lockTime[rg - 1];
    }

    function getEndVest(
        address token,
        uint256 amount
    ) public virtual view returns (uint256) {
        uint256 rg = MuLibrary.calcRange(amount, configs[token].range);
        if (rg == 0) {
            return configs[token].dustTime + getEnd(token, amount);
        }
        return configs[token].vesting[rg - 1] + getEnd(token, amount);
    }

    function addTimeline(
        address locker,
        address token,
        Timeline memory timeline
    ) internal virtual {
        uint256 len = boxs[locker][token].map.length;
        timelines[locker][token][len] = timeline;
        boxs[locker][token].map.push(len);
        if (len > 0) {
            for (uint256 i = len - 1; i >= 0; i--) {
                if (
                    timelines[locker][token][boxs[locker][token].map[i]].end >
                    timeline.end
                ) {
                    boxs[locker][token].map[i + 1] = boxs[locker][token].map[i];
                    boxs[locker][token].map[i] = len;
                } else {
                    break;
                }
            }
        }
    }

    function calcReward(
        address locker,
        address token
    ) public virtual view returns (uint256, uint256, uint256, bool, uint256[3] memory) {
        uint256 reward;
        bool reset;
        uint256 amounts = boxs[locker][token].amounts;
        uint256 xamounts = amounts;
        uint256 recent = boxs[locker][token].recentTime;
        uint256 tick = boxs[locker][token].tick;
        uint256 rg = MuLibrary.calcRange(amounts, configs[token].range);
        if (rg == 0 || amounts == 0 || tick == boxs[locker][token].map.length) {
            return (reward, amounts, tick, reset, [uint256(0), 0, 0]);
        }

        for (uint256 i = tick; i < boxs[locker][token].map.length; i++) {
            uint256 p = boxs[locker][token].map[i];
            if (timelines[locker][token][p].status == 0) {
                uint256 end = timelines[locker][token][p].end;
                if (block.timestamp >= end) {
                    uint256 times = end - recent;
                    reward +=
                        (times *
                            amounts *
                            configs[token].apr[
                                MuLibrary.calcRange(
                                    amounts,
                                    configs[token].range
                                ) - 1
                            ]) /
                        DENTIME;
                    recent = end;
                    amounts -= timelines[locker][token][p].amount;
                    if (amounts == 0) {
                        recent = uint256(block.timestamp);
                        tick = i + 1;
                        break;
                    }
                } else {
                    uint256 times = uint256(block.timestamp) - recent;
                    reward +=
                        (times *
                            amounts *
                            configs[token].apr[
                                MuLibrary.calcRange(
                                    amounts,
                                    configs[token].range
                                ) - 1
                            ]) /
                        DENTIME;
                    recent = uint256(block.timestamp);
                    tick = i;
                    break;
                }
            }
        }

        uint256 received = boxs[locker][token].received;
        uint256 s;
        uint256 b;
        uint256 t;
        uint256 r;
        if (configs[token].affiliate != address(0)) {
            (s, b, t, r) = IAffiliate(configs[token].affiliate).calc(locker);
            received += r;
        }
        uint256 maxReward = (xamounts * configs[token].maxReward[rg - 1]) /
            DENOMINATOR;
        uint256 de = reward + (s + b + t);
        if (received + de > maxReward) {
            reset = true;
            uint256 re = maxReward - received;
            reward = (reward * re) / de;
            s = (s * re) / de;
            b = (b * re) / de;
            t = (t * re) / de;
            return (
                reward + t,
                0,
                boxs[locker][token].map.length,
                reset,
                [s, b, t]
            );
        }
        return (reward + t, amounts, tick, reset, [s, b, t]);
    }

    function mintReward(
        address locker,
        address token,
        uint256 reward
    ) internal virtual returns (uint256 amountOut) {
        if (reward > 0) {
            boxs[locker][token].received += reward;
            Receiveds += reward;
            vault.withdraw(token, address(this), reward);
            return
                router.swapExactStableForToken(
                    address(0),
                    reward,
                    0,
                    token,
                    locker,
                    block.timestamp + 15 minutes
                );
        }
    }

    function _claim(
        address token,
        address locker
    )
        internal virtual
        started(token)
        returns (uint256, uint256, uint256, uint256[3] memory)
    {
        (
            uint256 reward,
            uint256 amounts,
            uint256 tick,
            bool reset,
            uint256[3] memory sbt
        ) = calcReward(locker, token);
        uint256 amountOut = mintReward(locker, token, reward);
        uint256 pre = boxs[locker][token].amounts;

        if (boxs[locker][token].amounts - amounts > 0) {
            boxs[locker][token].amounts = amounts;
        }

        if (boxs[locker][token].tick != tick) {
            for (uint256 i = boxs[locker][token].tick; i < tick; i++) {
                uint256 p = boxs[locker][token].map[i];
                if (reset) {
                    timelines[locker][token][p].status = 2;
                } else {
                    timelines[locker][token][p].status = 1;
                }
            }
            boxs[locker][token].tick = tick;
        }

        if (reset) {
            boxs[locker][token].received = 0;
        }

        boxs[locker][token].recentTime = uint256(block.timestamp);

        if (configs[token].affiliate != address(0)) {
            IAffiliate(configs[token].affiliate).claim(locker, sbt, reset);
        }
        return (reward - sbt[2], amountOut, pre, sbt);
    }

    function lock(
        address ref,
        address token,
        address locker,
        uint256 amount
    ) public virtual started(token) returns (uint256, uint256) {
        require(amount > 0, "Lock: amount");
        bool newLocker = false;
        if (boxs[locker][token].recentTime == 0) {
            newLocker = true;
            Lockers++;
        }
        (
            uint256 reward,
            uint256 amountOut,
            uint256 pre,
            uint256[3] memory sbt
        ) = _claim(token, locker);

        addTimeline(
            locker,
            token,
            Timeline(
                amount,
                uint256(block.timestamp),
                uint256(block.timestamp) + getEnd(token, amount),
                uint256(block.timestamp) + getEndVest(token, amount),
                uint256(block.timestamp) + getEnd(token, amount),
                0
            )
        );

        boxs[locker][token].amounts += amount;

        SafeERC20Upgradeable.safeTransferFrom(
            IERC20Upgradeable(launchpad.getStable(token)),
            msg.sender,
            Vault,
            amount
        );
        vault.deposit(token, launchpad.getStable(token), amount);
        vault.withdraw(
            token,
            configs[token].usageAddr,
            (amount * configs[token].usageRate) / DENOMINATOR
        );

        if (configs[token].affiliate != address(0)) {
            IAffiliate(configs[token].affiliate).referral(
                locker,
                ref,
                reward,
                pre,
                boxs[locker][token].amounts,
                newLocker,
                sbt
            );
        }
        return (reward, amountOut);
    }

    function claim(
        address ref,
        address token,
        address locker
    ) public virtual started(token) returns (uint256, uint256, uint256) {
        (
            uint256 reward,
            uint256 amountOut,
            uint256 pre,
            uint256[3] memory sbt
        ) = _claim(token, locker);
        if (configs[token].affiliate != address(0)) {
            IAffiliate(configs[token].affiliate).referral(
                locker,
                ref,
                reward,
                pre,
                boxs[locker][token].amounts,
                false,
                sbt
            );
        }
        return (reward, amountOut, pre);
    }

    function unlock(
        address token,
        address locker,
        uint256 from,
        uint256 to
    ) public virtual started(token) returns (uint256, uint256) {
        require(to <= boxs[locker][token].tick, "Lock: to");
        if (to == 0) {
            to = boxs[locker][token].tick;
        }
        uint256 pay = 0;
        for (uint256 i = from; i < to; i++) {
            uint256 p = boxs[locker][token].map[i];
            if (timelines[locker][token][p].status == 1) {
                uint256 endVest = timelines[locker][token][p].endVest;
                uint256 times;
                if (block.timestamp >= endVest) {
                    times = endVest - timelines[locker][token][p].recent;
                    timelines[locker][token][p].status = 2;
                } else {
                    times =
                        uint256(block.timestamp) -
                        timelines[locker][token][p].recent;
                    timelines[locker][token][p].recent = uint256(
                        block.timestamp
                    );
                }
                pay +=
                    (times * timelines[locker][token][p].amount) /
                    (timelines[locker][token][p].endVest -
                        timelines[locker][token][p].end);
            }
        }
        require(pay > 0, "Lock: pay");
        if (configs[token].receiveToken == token) {
            uint256 amountOut = mintReward(locker, token, pay);
            return (pay, amountOut);
        } else {
            vault.withdraw(token, locker, pay);
            return (pay, 0);
        }
    }

    function getConfig(
        address token
    )
        public
        virtual
        view
        returns (
            address lockToken,
            uint256 startTime,
            uint256[] memory range,
            uint256[] memory apr,
            uint256[] memory lockTime,
            uint256 dustTime,
            uint256[] memory maxReward,
            uint256[] memory vesting,
            address receiveToken,
            address affiliate,
            uint256 usageRate,
            address usageAddr
        )
    {
        return (
            configs[token].lockToken,
            configs[token].startTime,
            configs[token].range,
            configs[token].apr,
            configs[token].lockTime,
            configs[token].dustTime,
            configs[token].maxReward,
            configs[token].vesting,
            configs[token].receiveToken,
            configs[token].affiliate,
            configs[token].usageRate,
            configs[token].usageAddr
        );
    }

    function getBox(
        address token,
        address locker
    )
        public
        virtual
        view
        returns (
            uint256 recentTime,
            uint256 amounts,
            uint256 received,
            uint256 tick
        )
    {
        return (
            boxs[locker][token].recentTime,
            boxs[locker][token].amounts,
            boxs[locker][token].received,
            boxs[locker][token].tick
        );
    }

    function getMap(
        address token,
        address locker
    ) public virtual view returns (uint256[] memory) {
        return boxs[locker][token].map;
    }

    function getMarket(
        address token
    ) public virtual view returns (uint256[] memory, uint256[] memory) {
        return (configs[token].range, configs[token].apr);
    }
}
