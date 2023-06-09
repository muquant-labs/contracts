// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts/utils/Arrays.sol";
import "./interfaces/ICRC20.sol";

contract Launchpad is Initializable, AccessControlUpgradeable, UUPSUpgradeable {
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant APPROVE_ROLE = keccak256("APPROVE_ROLE");
    bytes32 public constant STABLE_ROLE = keccak256("STABLE_ROLE");
    bytes32 public constant ROUTER_ROLE = keccak256("ROUTER_ROLE");
    bytes32 public constant ROUTER = keccak256("ROUTER");
    bytes32 public constant LOCK_ROLE = keccak256("LOCK_ROLE");

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize() public initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(UPGRADER_ROLE, msg.sender);
        _setRoleAdmin(UPGRADER_ROLE, UPGRADER_ROLE);
        _grantRole(APPROVE_ROLE, msg.sender);
        _setRoleAdmin(APPROVE_ROLE, APPROVE_ROLE);
        _grantRole(STABLE_ROLE, msg.sender);
        _setRoleAdmin(STABLE_ROLE, STABLE_ROLE);
        _grantRole(ROUTER_ROLE, msg.sender);
        _setRoleAdmin(ROUTER_ROLE, ROUTER_ROLE);
        _grantRole(LOCK_ROLE, msg.sender);
        _setRoleAdmin(LOCK_ROLE, LOCK_ROLE);
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(UPGRADER_ROLE) {}

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

    address[] public stableList;
    mapping(address => bool) public stable;
    mapping(address => Pair) public pairs;
    mapping(address => Limit) public limits;
    mapping(address => Agent) public agent;
    mapping(address => mapping(address => bool)) public votes;
    mapping(address => mapping(address => uint256)) public owned;
    mapping(address => mapping(address => uint256)) public last;

    uint256 public constant DENOMINATOR = 10000;
    address public Lock;
    address public Router;
    uint256 public Tokens;
    address public Original;

    event NEWPAIR(
        address indexed token,
        address indexed stable,
        uint256 base,
        uint256 quote,
        uint256 fees
    );

    modifier onlyCreator(address _token) {
        require(
            msg.sender == pairs[_token].sponsored ||
                msg.sender == agent[_token].creator,
            "Launchpad: creator"
        );
        _;
    }

    modifier beforeApprove(address _token) {
        require(!agent[_token].approval, "Pair: approved");
        _;
    }

    modifier validLimit(
        uint256 _limitBySupply,
        uint256 _limitByBalance,
        uint256 _taxOverLimit,
        uint256 _frequency
    ) {
        require(_limitBySupply <= DENOMINATOR, "Limit: supply");
        require(_limitByBalance <= DENOMINATOR, "Limit: balance");
        require(_taxOverLimit <= DENOMINATOR, "Limit: tax");
        require(_frequency <= 7 days, "Limit: frequency");
        _;
    }

    modifier validToken(address _token) {
        require(_token != address(0) && _token != address(this), "Pair: token");
        _;
    }

    function TOKEN_ROLE(address _token) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(_token));
    }

    function addStable(address _stable) external onlyRole(STABLE_ROLE) {
        stable[_stable] = true;
        stableList.push(_stable);
    }

    function approve(address _token) external onlyRole(APPROVE_ROLE) {
        agent[_token].approval = true;
        ICRC20(_token).setTransferFee(pairs[_token].fees);
        ICRC20(_token).transferOwnership(Router);
        Tokens++;
        if (Tokens == 1) {
            Original = _token;
        }
    }

    function reject(address _token) external onlyRole(APPROVE_ROLE) {
        pairs[_token] = Pair(
            address(0),
            0,
            0,
            0,
            0,
            [uint256(0), 0, 0],
            address(0)
        );
        agent[_token] = Agent(address(0), 0, false, 0);
        limits[_token] = Limit(0, 0, 0, 0, 0, 0, 0);
        ICRC20(_token).transferOwnership(agent[_token].creator);
    }

    function setRouter(address _router) external onlyRole(ROUTER_ROLE) {
        Router = _router;
        _grantRole(ROUTER, _router);
        _setRoleAdmin(ROUTER, ROUTER);
    }

    function setLock(address _lock) external onlyRole(LOCK_ROLE) {
        Lock = _lock;
    }

    function addPair(
        address _token,
        address _stable,
        uint256 _base,
        uint256 _quote,
        uint256 _fees,
        uint256[3] memory _rates,
        address _sponsored
    ) public virtual beforeApprove(_token) validToken(_token) {
        require(ICRC20(_token).totalSupply() == 0, "Pair: supply > 0");
        require(ICRC20(_token).decimals() == 18, "Pair: decimals");
        require(ICRC20(_token).owner() == address(this), "Pair: owner");

        require(stable[_stable], "Pair: stable");
        require(_base > 0, "Pair: base");
        require(_quote > 0, "Pair: quote");
        require(_fees < DENOMINATOR, "Pair: fees");
        require(
            _rates[0] + _rates[1] + _rates[2] == DENOMINATOR,
            "Pair: rates"
        );
        require(
            _sponsored != address(0) && _sponsored != address(this),
            "Pair: sponsored"
        );

        require(
            pairs[_token].stable == address(0) &&
                pairs[_token].liquidity == 0 &&
                pairs[_token].base == 0 &&
                pairs[_token].quote == 0 &&
                pairs[_token].fees == 0,
            "Pair: exists"
        );

        pairs[_token] = Pair(
            _stable,
            0,
            _base,
            _quote,
            _fees,
            _rates,
            _sponsored
        );

        agent[_token] = Agent(msg.sender, uint256(block.timestamp), false, 0);
        _grantRole(TOKEN_ROLE(_token), msg.sender);
        _setRoleAdmin(TOKEN_ROLE(_token), TOKEN_ROLE(_token));
    }

    function modifySponsored(
        address _token,
        address _sponsored
    ) public virtual onlyCreator(_token) validToken(_token) {
        require(
            _sponsored != address(0) && _sponsored != address(this),
            "Pair: sponsored"
        );
        pairs[_token].sponsored = _sponsored;
    }

    function modifyRates(
        address _token,
        uint256[3] memory _rates
    ) public virtual onlyCreator(_token) validToken(_token) {
        require(
            _rates[0] + _rates[1] + _rates[2] == DENOMINATOR,
            "Pair: rates"
        );
        pairs[_token].rates = _rates;
    }

    function modifyEquation(
        address _token,
        address _stable,
        uint256 _base,
        uint256 _quote
    ) public virtual onlyCreator(_token) beforeApprove(_token) validToken(_token) {
        require(stable[_stable], "Pair: stable");
        require(_base > 0, "Pair: base");
        require(_quote > 0, "Pair: quote");
        pairs[_token].base = _base;
        pairs[_token].quote = _quote;
        pairs[_token].stable = _stable;
    }

    function modifyFees(
        address _token,
        uint256 _fees
    ) public virtual onlyRole(TOKEN_ROLE(_token)) validToken(_token) {
        require(_fees <= DENOMINATOR, "Pair: fees");
        pairs[_token].fees = _fees;
    }

    function addLimit(
        address _token,
        uint256 _startTime,
        uint256 _minVotes,
        uint256 _limitBySupply,
        uint256 _limitByBalance,
        uint256 _taxOverLimit,
        uint256 _frequency,
        uint256 _maxByOwner
    )
        public
        virtual
        onlyCreator(_token)
        beforeApprove(_token)
        validLimit(_limitBySupply, _limitByBalance, _taxOverLimit, _frequency)
    {
        require(_token != address(0) && _token != address(this), "Pair: token");
        limits[_token] = Limit(
            _startTime,
            _minVotes,
            _limitBySupply,
            _limitByBalance,
            _taxOverLimit,
            _frequency,
            _maxByOwner
        );
    }

    function modifyLimit(
        address _token,
        uint256 _limitBySupply,
        uint256 _limitByBalance,
        uint256 _taxOverLimit,
        uint256 _frequency
    )
        public
        virtual
        onlyRole(TOKEN_ROLE(_token))
        validLimit(_limitBySupply, _limitByBalance, _taxOverLimit, _frequency)
        validToken(_token)
    {
        limits[_token].limitBySupply = _limitBySupply;
        limits[_token].limitByBalance = _limitByBalance;
        limits[_token].taxOverLimit = _taxOverLimit;
        limits[_token].frequency = _frequency;
    }

    function modifyTime(
        address _token,
        uint256 _startTime,
        uint256 _minVotes
    ) public virtual onlyCreator(_token) beforeApprove(_token) validToken(_token) {
        limits[_token].startTime = _startTime;
        limits[_token].minVotes = _minVotes;
    }

    function modifyMaxOwn(
        address _token,
        uint256 _maxByOwner
    ) public virtual onlyRole(TOKEN_ROLE(_token)) validToken(_token) {
        limits[_token].maxByOwner = _maxByOwner;
    }

    function vote(address _token) public virtual validToken(_token) {
        require(agent[_token].approval, "Vote: not");
        require(!votes[_token][msg.sender], "Vote: already voted");
        agent[_token].votes++;
        votes[_token][msg.sender] = true;
    }

    function enableSwap(address _token) public virtual view returns (bool) {
        return
            agent[_token].approval &&
            block.timestamp >= limits[_token].startTime &&
            agent[_token].votes >= limits[_token].minVotes;
    }

    function getPair(address _token) public view returns (Pair memory) {
        return pairs[_token];
    }

    function getLimit(address _token) public view returns (Limit memory) {
        return limits[_token];
    }

    function getAgent(address _token) public view returns (Agent memory) {
        return agent[_token];
    }

    function getReserves(
        address _token
    ) public view returns (uint256, uint256, uint256) {
        return (pairs[_token].base, pairs[_token].quote, pairs[_token].fees);
    }

    function checkOwned(
        address _sender,
        address _token,
        uint256 _amount
    ) public virtual view returns (bool) {
        if (_sender == Lock) {
            return true;
        }
        return owned[_sender][_token] + _amount < limits[_token].maxByOwner;
    }

    function increaseOwned(
        address _sender,
        address _token,
        uint256 _amount
    ) public virtual onlyRole(ROUTER) validToken(_token) {
        owned[_sender][_token] += _amount;
    }

    function checkLimitBySupply(
        address _token,
        uint256 _amount
    ) public virtual view returns (bool) {
        return
            _amount <=
            (limits[_token].limitBySupply * ICRC20(_token).totalSupply()) /
                DENOMINATOR;
    }

    function getTax(
        address _sender,
        address _token,
        uint256 _amountIn,
        uint256 _amountOut
    ) public virtual view returns (uint256 tax) {
        tax = _amountIn <=
            (limits[_token].limitByBalance *
                ICRC20(_token).balanceOf(_sender)) /
                DENOMINATOR
            ? 0
            : (_amountOut * limits[_token].taxOverLimit) / DENOMINATOR;
    }

    function checkFrequency(
        address _sender,
        address _token
    ) public virtual view returns (bool) {
        return
            last[_sender][_token] + limits[_token].frequency <= block.timestamp;
    }

    function setFrequency(
        address _sender,
        address _token
    ) public virtual onlyRole(ROUTER) validToken(_token) {
        last[_sender][_token] = uint256(block.timestamp);
    }

    function checkStable(address _token) public virtual view returns (bool) {
        return stable[_token];
    }

    function getStable(address _token) public virtual view returns (address) {
        return pairs[_token].stable;
    }

    function sync(address _token) public virtual onlyRole(ROUTER) validToken(_token) {
        uint256 x0 = ICRC20(_token).totalSupply();
        if (x0 > 0) {
            uint256 y0 = pairs[_token].liquidity;
            uint256 x = pairs[_token].base;
            uint256 y = (x0 * y0 + y0 * x) / x0;
            if (y != pairs[_token].quote) {
                pairs[_token].quote = y;
            }
        }
    }

    function reserves(
        address[2] memory _path,
        uint256[2] memory _amounts
    ) public virtual onlyRole(ROUTER) returns (bool) {
        if (stable[_path[0]]) {
            pairs[_path[1]].liquidity += _amounts[0];
            pairs[_path[1]].quote += _amounts[0];
            pairs[_path[1]].base -= _amounts[1];
            return true;
        } else {
            pairs[_path[0]].liquidity -= _amounts[1];
            pairs[_path[0]].quote -= _amounts[1];
            pairs[_path[0]].base += _amounts[0];
            return false;
        }
    }

    function getCreator(address _token) public virtual view returns (address) {
        return agent[_token].creator;
    }

    function getStableList() public virtual view returns (address[] memory) {
        return stableList;
    }

    function combine(
        address[3] memory addrs,
        uint256[3] memory u8,
        uint256[7] memory u4,
        uint256[3] memory u5
    ) public virtual {
        addPair(
            addrs[0],
            addrs[1],
            u8[0],
            u8[1],
            u4[0],
            [u4[1], u4[2], u4[3]],
            addrs[2]
        );
        addLimit(addrs[0], u5[0], u5[1], u4[4], u4[5], u4[6], u5[2], u8[2]);
        emit NEWPAIR(addrs[0], addrs[1], u8[0], u8[1], u4[0]);
    }
}
