// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "./interfaces/ILaunchpad.sol";
import "./interfaces/ICRC20.sol";
import "./interfaces/IVault.sol";
import "./libraries/MuLibrary.sol";

contract Router is Initializable, AccessControlUpgradeable, UUPSUpgradeable {
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant LOTTERY_ROLE = keccak256("LOTTERY_ROLE");
    bytes32 public constant REFS_ROLE = keccak256("REFS_ROLE");
    bytes32 public constant LAUNCHPAD_ROLE = keccak256("LAUNCHPAD_ROLE");
    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize() public initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(UPGRADER_ROLE, msg.sender);
        _setRoleAdmin(UPGRADER_ROLE, UPGRADER_ROLE);
        _grantRole(LOTTERY_ROLE, msg.sender);
        _grantRole(REFS_ROLE, msg.sender);
        _grantRole(LAUNCHPAD_ROLE, msg.sender);
        _setRoleAdmin(LAUNCHPAD_ROLE, LAUNCHPAD_ROLE);
        _grantRole(VAULT_ROLE, msg.sender);
        _setRoleAdmin(VAULT_ROLE, VAULT_ROLE);
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(UPGRADER_ROLE) {}

    address public lottery;
    address public defaultRef;
    ILaunchpad public launchpad;
    address public Vault;
    IVault public vault;
    mapping(address => address) public refs;
    uint256 public volumes;
    uint256 public muVol;
    uint256 public users;
    mapping(address => bool) public isUser;

    event SWAP(
        address indexed from,
        address to,
        address indexed referral,
        bool side,
        address stable,
        address indexed token,
        uint256 quote,
        uint256 base,
        uint256 liquidity,
        uint256 amountIn,
        uint256 amountOut,
        uint256 fees,
        uint256 timestamp
    );

    modifier ensure(uint256 deadline) {
        require(deadline >= block.timestamp, "Router: EXPIRED");
        _;
    }

    modifier enable(address token) {
        require(launchpad.enableSwap(token), "Launchpad: DISABLED");
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

    function setLottery(address _lottery) external onlyRole(LOTTERY_ROLE) {
        lottery = _lottery;
    }

    function setDefaultRef(address _defaultRef) external onlyRole(REFS_ROLE) {
        defaultRef = _defaultRef;
    }

    function _swap(
        address to,
        address[2] memory path,
        uint256[2] memory amounts
    ) internal virtual {
        if (launchpad.reserves(path, amounts)) {
            SafeERC20Upgradeable.safeTransferFrom(
                IERC20Upgradeable(path[0]),
                msg.sender,
                Vault,
                amounts[0]
            );
            vault.deposit(path[1], path[0], amounts[0]);
            ICRC20(path[1]).mint(to, amounts[1]);
            volumes += amounts[0];
            if (path[1] == launchpad.Original()) {
                muVol += amounts[0];
            }
        } else {
            ICRC20(path[0]).burnFrom(msg.sender, amounts[0]);
            vault.withdraw(path[0], to, amounts[1]);
            volumes += amounts[1];
            if (path[0] == launchpad.Original()) {
                muVol += amounts[1];
            }
        }
        if (!isUser[msg.sender]) {
            isUser[msg.sender] = true;
            users += 1;
        }
    }

    function _fees(
        address token,
        uint256 amount,
        uint256[3] memory rates,
        address[2] memory addrs
    ) internal virtual {
        if (amount > 0) {
            if (rates[0] > 0) {
                SafeERC20Upgradeable.safeTransferFrom(
                    IERC20Upgradeable(token),
                    msg.sender,
                    addrs[0],
                    (amount * rates[0]) / 10000
                );
            }
            if (rates[1] > 0) {
                SafeERC20Upgradeable.safeTransferFrom(
                    IERC20Upgradeable(token),
                    msg.sender,
                    addrs[1],
                    (amount * rates[1]) / 10000
                );
            }
            if (rates[2] > 0) {
                if (launchpad.checkStable(token)) {
                    SafeERC20Upgradeable.safeTransferFrom(
                        IERC20Upgradeable(token),
                        msg.sender,
                        lottery,
                        (amount * rates[2]) / 10000
                    );
                } else {
                    ICRC20(token).burnFrom(
                        msg.sender,
                        (amount * rates[2]) / 10000
                    );
                }
            }
        }
    }

    function _tax(address token, uint256 tax) internal virtual {
        if (tax > 0) {
            SafeERC20Upgradeable.safeTransfer(
                IERC20Upgradeable(token),
                lottery,
                tax
            );
        }
    }

    function _ref(address ref) internal virtual {
        if (refs[msg.sender] == address(0)) {
            refs[msg.sender] = defaultRef;
            if (ref != address(0)) {
                refs[msg.sender] = ref;
            }
        }
    }

    function swapExactStableForToken(
        address ref,
        uint256 amountIn,
        uint256 amountOutMin,
        address token,
        address to,
        uint256 deadline
    ) public virtual ensure(deadline) enable(token) returns (uint256 amountOut) {
        _ref(ref);
        launchpad.sync(token);

        ILaunchpad.Pair memory pair = launchpad.getPair(token);
        amountOut = MuLibrary.getAmountOut(
            amountIn,
            pair.quote,
            pair.base,
            pair.fees
        );

        require(
            amountOut >= amountOutMin,
            "MuRouter: INSUFFICIENT_OUTPUT_AMOUNT"
        );
        require(
            launchpad.checkOwned(msg.sender, token, amountOut),
            "Exceeded the limit that can be owned"
        );
        launchpad.increaseOwned(msg.sender, token, amountOut);

        _swap(
            to,
            [pair.stable, token],
            [(amountIn * (10000 - pair.fees)) / 10000, amountOut]
        );
        _fees(
            pair.stable,
            amountIn - (amountIn * (10000 - pair.fees)) / 10000,
            pair.rates,
            [pair.sponsored, refs[msg.sender]]
        );

        emit SWAP(
            msg.sender,
            to,
            refs[msg.sender],
            true,
            pair.stable,
            token,
            pair.quote + amountIn,
            pair.base - amountOut,
            pair.liquidity + amountIn,
            amountIn,
            amountOut,
            amountIn - (amountIn * (10000 - pair.fees)) / 10000,
            block.timestamp
        );
    }

    function swapExactTokenForStable(
        address ref,
        uint256 amountIn,
        uint256 amountOutMin,
        address token,
        address to,
        uint256 deadline
    ) public virtual ensure(deadline) enable(token) returns (uint256 amountOut) {
        _ref(ref);
        require(
            launchpad.checkFrequency(msg.sender, token),
            "Exceed the time allowed"
        );
        launchpad.setFrequency(msg.sender, token);
        require(
            launchpad.checkLimitBySupply(token, amountIn),
            "Exceeded the limit on total supply"
        );
        launchpad.sync(token);

        ILaunchpad.Pair memory pair = launchpad.getPair(token);
        amountOut = MuLibrary.getAmountOut(
            amountIn,
            pair.base,
            pair.quote,
            pair.fees
        );
        require(
            amountOut >= amountOutMin,
            "MuRouter: INSUFFICIENT_OUTPUT_AMOUNT"
        );

        _swap(
            to,
            [token, pair.stable],
            [(amountIn * (10000 - pair.fees)) / 10000, amountOut]
        );
        _fees(
            token,
            amountIn - (amountIn * (10000 - pair.fees)) / 10000,
            pair.rates,
            [pair.sponsored, refs[msg.sender]]
        );
        _tax(token, launchpad.getTax(msg.sender, token, amountIn, amountOut));

        emit SWAP(
            msg.sender,
            to,
            refs[msg.sender],
            false,
            pair.stable,
            token,
            pair.quote - amountOut,
            pair.base + amountIn,
            pair.liquidity - amountOut,
            amountIn,
            amountOut,
            amountIn - (amountIn * (10000 - pair.fees)) / 10000,
            block.timestamp
        );
    }

    function swapStableForExactToken(
        address ref,
        uint256 amountOut,
        uint256 amountInMax,
        address token,
        address to,
        uint256 deadline
    ) public virtual ensure(deadline) enable(token) returns (uint256 amountIn) {
        _ref(ref);
        require(
            launchpad.checkOwned(msg.sender, token, amountOut),
            "Exceeded the limit that can be owned"
        );
        launchpad.increaseOwned(msg.sender, token, amountOut);
        launchpad.sync(token);

        ILaunchpad.Pair memory pair = launchpad.getPair(token);
        amountIn = MuLibrary.getAmountIn(
            amountOut,
            pair.quote,
            pair.base,
            pair.fees
        );

        require(amountIn <= amountInMax, "MuRouter: EXCESSIVE_INPUT_AMOUNT");

        _swap(
            to,
            [pair.stable, token],
            [(amountIn * (10000 - pair.fees)) / 10000, amountOut]
        );
        _fees(
            pair.stable,
            amountIn - (amountIn * (10000 - pair.fees)) / 10000,
            pair.rates,
            [pair.sponsored, refs[msg.sender]]
        );

        emit SWAP(
            msg.sender,
            to,
            refs[msg.sender],
            true,
            pair.stable,
            token,
            pair.quote + amountIn,
            pair.base - amountOut,
            pair.liquidity + amountIn,
            amountIn,
            amountOut,
            amountIn - (amountIn * (10000 - pair.fees)) / 10000,
            block.timestamp
        );
    }

    function swapTokenForExactStable(
        address ref,
        uint256 amountOut,
        uint256 amountInMax,
        address token,
        address to,
        uint256 deadline
    ) public virtual ensure(deadline) enable(token) returns (uint256 amountIn) {
        _ref(ref);
        require(
            launchpad.checkFrequency(msg.sender, token),
            "Exceed the time allowed"
        );
        launchpad.setFrequency(msg.sender, token);
        launchpad.sync(token);

        ILaunchpad.Pair memory pair = launchpad.getPair(token);
        amountIn = MuLibrary.getAmountIn(
            amountOut,
            pair.base,
            pair.quote,
            pair.fees
        );

        require(amountIn <= amountInMax, "MuRouter: EXCESSIVE_INPUT_AMOUNT");
        require(
            launchpad.checkLimitBySupply(token, amountIn),
            "Exceeded the limit on total supply"
        );

        _swap(
            to,
            [token, pair.stable],
            [(amountIn * (10000 - pair.fees)) / 10000, amountOut]
        );
        _fees(
            token,
            amountIn - (amountIn * (10000 - pair.fees)) / 10000,
            pair.rates,
            [pair.sponsored, refs[msg.sender]]
        );
        _tax(token, launchpad.getTax(msg.sender, token, amountIn, amountOut));

        emit SWAP(
            msg.sender,
            to,
            refs[msg.sender],
            false,
            pair.stable,
            token,
            pair.quote - amountOut,
            pair.base + amountIn,
            pair.liquidity - amountOut,
            amountIn,
            amountOut,
            amountIn - (amountIn * (10000 - pair.fees)) / 10000,
            block.timestamp
        );
    }
}
