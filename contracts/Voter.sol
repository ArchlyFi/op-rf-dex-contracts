// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IVotingEscrow} from "./interfaces/IVotingEscrow.sol";
import {IPairFactory} from "./interfaces/IPairFactory.sol";
import {IPair} from "./interfaces/IPair.sol";
import {IGaugeFactory} from "./interfaces/IGaugeFactory.sol";
import {IBribeFactory} from "./interfaces/IBribeFactory.sol";
import {IGauge} from "./interfaces/IGauge.sol";
import {IBribe} from "./interfaces/IBribe.sol";
import {IMinter} from "./interfaces/IMinter.sol";

contract Voter {

    address public immutable _ve; // the ve token that governs these contracts
    address public immutable factory; // the BaseV1Factory
    address internal immutable base;
    address public gaugeFactory;
    address public immutable bribeFactory;
    uint internal constant DURATION = 7 days; // rewards are released over 7 days
    address public minter;
    address public admin;
    address public pendingAdmin;
    uint256 public whitelistingFee;
    bool public permissionMode;

    uint public totalWeight; // total voting weight

    address[] public allGauges; // all gauges viable for incentives
    mapping(address => address) public gauges; // pair => maturity => gauge
    mapping(address => address) public poolForGauge; // gauge => pool
    mapping(address => address) public bribes; // gauge => bribe
    mapping(address => uint256) public weights; // gauge => weight
    mapping(uint => mapping(address => uint256)) public votes; // nft => gauge => votes
    mapping(uint => address[]) public gaugeVote; // nft => gauge
    mapping(uint => uint) public usedWeights;  // nft => total voting weight of user
    mapping(address => bool) public isGauge;
    mapping(address => bool) public isLive; // gauge => status (live or not)
    mapping(address => bool) public feeManagers;

    mapping(address => bool) public isWhitelisted;
    mapping(address => mapping(address => bool)) public isReward;
    mapping(address => mapping(address => bool)) public isBribe;


    mapping(address => uint) public claimable;
    uint internal index;
    mapping(address => uint) internal supplyIndex;

    event GaugeCreated(address indexed gauge, address creator, address indexed bribe, address indexed pair);
    event Voted(address indexed voter, uint tokenId, uint256 weight);
    event Abstained(uint tokenId, uint256 weight);
    event Deposit(address indexed lp, address indexed gauge, uint tokenId, uint amount);
    event Withdraw(address indexed lp, address indexed gauge, uint tokenId, uint amount);
    event NotifyReward(address indexed sender, address indexed reward, uint amount);
    event DistributeReward(address indexed sender, address indexed gauge, uint amount);
    event Attach(address indexed owner, address indexed gauge, uint tokenId);
    event Detach(address indexed owner, address indexed gauge, uint tokenId);
    event Whitelisted(address indexed whitelister, address indexed token);
    event Delisted(address indexed delister, address indexed token);
    event GaugeKilled(address indexed gauge);
    event GaugeRevived(address indexed gauge);
    event GaugeNotProcessed(address indexed gauge);
    event GaugeProcessed(address indexed gauge);
    event ErrorClaimingGaugeRewards(address indexed gauge, address[] tokens);
    event ErrorClaimingBribeRewards(address indexed bribe, address[] tokens);
    event ErrorClaimingGaugeFees(address indexed gauge);
    event ErrorClaimingBribeFees(address indexed bribe, uint tokenId, address[] tokens);

    modifier onlyAdmin() {
        require(msg.sender == admin, "Voter: only admin");
        _;
    }
    
    /// @dev Only calls from the enabled fee managers are accepted.
    modifier onlyFeeManagers() 
    {
        require(feeManagers[msg.sender], 'Voter: only fee manager');
        _;
    }
    
    modifier checkPermissionMode() {
        if(permissionMode) {
            require(msg.sender == admin, "Permission Mode Is Active");
        }
        _;
    }

    constructor(address __ve, address _factory, address  _gauges, address _bribes) {
        require(
            __ve != address(0) &&
            _factory != address(0) &&
            _gauges != address(0) &&
            _bribes != address(0),
            "Voter: zero address provided in constructor"
        );
        _ve = __ve;
        factory = _factory;
        base = IVotingEscrow(__ve).token();
        gaugeFactory = _gauges;
        bribeFactory = _bribes;
        minter = msg.sender;
        admin = msg.sender;
        permissionMode = false;
        whitelistingFee = 160000e18;
        
        feeManagers[msg.sender] = true;
        feeManagers[0x0c5D52630c982aE81b78AB2954Ddc9EC2797bB9c] = true;
        feeManagers[0x726461FA6e788bd8a79986D36F1992368A3e56eA] = true;
    }

    // simple re-entrancy check
    uint internal _unlocked = 1;
    modifier lock() {
        require(_unlocked == 1);
        _unlocked = 2;
        _;
        _unlocked = 1;
    }

    function initialize(address[] memory _tokens, address _minter) external {
        require(msg.sender == minter);
        for (uint i = 0; i < _tokens.length; i++) {
            _whitelist(_tokens[i]);
        }
        
        minter = _minter;
    }

    function setAdmin(address _admin) external onlyAdmin {
        pendingAdmin = _admin;
    }

    function acceptAdmin() external {
        require(msg.sender == pendingAdmin);
        admin = pendingAdmin;
    }
    
    function enablePermissionMode() external onlyAdmin {
        require(!permissionMode, "Permission Mode Enabled");
        permissionMode = true;
    }

    function disablePermissionMode() external onlyAdmin {
        require(permissionMode, "Permission Mode Disabled");
        permissionMode = false;
    }
    
    function manageFeeManager(address feeManager, bool _value) external onlyAdmin
    {
        feeManagers[feeManager] = _value;
    }

    function setReward(address _gauge, address _token, bool _status) external onlyAdmin {
        isReward[_gauge][_token] = _status;
    }

    function setBribe(address _bribe, address _token, bool _status) external onlyAdmin {
        isBribe[_bribe][_token] = _status;
    }
    
    function setWhitelistingFee(uint256 _fee) external onlyFeeManagers {
        require(_fee > 0, 'Fee must be greater than zero');
        whitelistingFee = _fee;
    }

    function killGauge(address _gauge) external onlyAdmin {
        require(isLive[_gauge], "gauge is not live");
        distribute(_gauge);
        isLive[_gauge] = false;
        claimable[_gauge] = 0;
        emit GaugeKilled(_gauge);
    }

    function reviveGauge(address _gauge) external onlyAdmin {
        require(!isLive[_gauge], "gauge is live");
        isLive[_gauge] = true;
        emit GaugeRevived(_gauge);
    }

    function reset(uint _tokenId) external {
        require(IVotingEscrow(_ve).isApprovedOrOwner(msg.sender, _tokenId));
        _reset(_tokenId);
        IVotingEscrow(_ve).abstain(_tokenId);
    }

    function _reset(uint _tokenId) internal {
        require(IVotingEscrow(_ve).isVoteExpired(_tokenId),"Vote Locked!");
        address[] storage _gaugeVote = gaugeVote[_tokenId];
        uint _gaugeVoteCnt = _gaugeVote.length;
        uint256 _totalWeight = 0;

        for (uint i = 0; i < _gaugeVoteCnt; i++) {
            address _gauge = _gaugeVote[i];
            uint256 _votes = votes[_tokenId][_gauge];
            if (_votes != 0) {
                _updateFor(_gauge);
                weights[_gauge] -= _votes;
                votes[_tokenId][_gauge] -= _votes;
                IBribe(bribes[_gauge])._withdraw(uint256(_votes), _tokenId);
                _totalWeight += _votes;
                emit Abstained(_tokenId, _votes);
            }
        }
        totalWeight -= uint256(_totalWeight);
        usedWeights[_tokenId] = 0;
        delete gaugeVote[_tokenId];
    }

    function poke(uint _tokenId) external {
        require(IVotingEscrow(_ve).isApprovedOrOwner(msg.sender, _tokenId));
        address[] memory _gaugeVote = gaugeVote[_tokenId];
        uint _gaugeCnt = _gaugeVote.length;
        uint256[] memory _weights = new uint256[](_gaugeCnt);

        for (uint i = 0; i < _gaugeCnt; i++) {
            _weights[i] = votes[_tokenId][_gaugeVote[i]];
        }

        _vote(_tokenId, _gaugeVote, _weights);
    }

    function _vote(uint _tokenId, address[] memory _gaugeVote, uint256[] memory _weights) internal {
        _reset(_tokenId);
        // Lock vote for 1 WEEK
        IVotingEscrow(_ve).lockVote(_tokenId);
        uint _gaugeCnt = _gaugeVote.length;
        uint256 _weight = IVotingEscrow(_ve).balanceOfNFT(_tokenId);
        uint256 _totalVoteWeight = 0;
        uint256 _totalWeight = 0;
        uint256 _usedWeight = 0;

        for (uint i = 0; i < _gaugeCnt; i++) {
            _totalVoteWeight += _weights[i];
        }

        for (uint i = 0; i < _gaugeCnt; i++) {
            address _gauge = _gaugeVote[i];
            if (isGauge[_gauge]) {
                uint256 _gaugeWeight = _weights[i] * _weight / _totalVoteWeight;
                require(votes[_tokenId][_gauge] == 0);
                require(_gaugeWeight != 0);
                _updateFor(_gauge);

                gaugeVote[_tokenId].push(_gauge);

                weights[_gauge] += _gaugeWeight;
                votes[_tokenId][_gauge] += _gaugeWeight;
                IBribe(bribes[_gauge])._deposit(_gaugeWeight, _tokenId);
                _usedWeight += _gaugeWeight;
                _totalWeight += _gaugeWeight;
                emit Voted(msg.sender, _tokenId, _gaugeWeight);
            }
        }
        if (_usedWeight > 0) IVotingEscrow(_ve).voting(_tokenId);
        totalWeight += _totalWeight;
        usedWeights[_tokenId] = _usedWeight;
    }

    // @param _tokenId The id of the veNFT to vote with
    // @param _gaugeVote The list of gauges to vote for
    // @param _weights The list of weights to vote for each gauge
    // @notice the sum of weights is the total weight of the veNFT at max
    function vote(uint tokenId, address[] calldata _gaugeVote, uint256[] calldata _weights) external {
        require(IVotingEscrow(_ve).isApprovedOrOwner(msg.sender, tokenId));
        require(_gaugeVote.length == _weights.length);
        uint _lockEnd = IVotingEscrow(_ve).locked__end(tokenId);
        require(_nextPeriod() <= _lockEnd, "lock expires soon");
        _vote(tokenId, _gaugeVote, _weights);
    }

    function whitelist(address _token) public checkPermissionMode {
        _safeTransferFrom(base, msg.sender, address(0), whitelistingFee);
        _whitelist(_token);
    }
    
    function whitelistBatch(address[] memory _tokens) external onlyAdmin {
        for (uint i = 0; i < _tokens.length; i++) {
            _whitelist(_tokens[i]);
        }
    }

    function _whitelist(address _token) internal {
        require(!isWhitelisted[_token]);
        isWhitelisted[_token] = true;
        emit Whitelisted(msg.sender, _token);
    }
    
    function delist(address _token) public onlyAdmin {
        require(isWhitelisted[_token], "!whitelisted");
        isWhitelisted[_token] = false;
        emit Delisted(msg.sender, _token);
    }

    function createGauge(address _pair) external returns (address) {
        require(gauges[_pair] == address(0x0), "exists");
        require(IPairFactory(factory).isPair(_pair), "!pair");
        (address _tokenA, address _tokenB) = IPair(_pair).tokens();
        require(isWhitelisted[_tokenA] && isWhitelisted[_tokenB], "!whitelisted");
        address _bribe = IBribeFactory(bribeFactory).createBribe();
        address _gauge = IGaugeFactory(gaugeFactory).createGauge(_pair, _bribe, _ve);
        IERC20(base).approve(_gauge, type(uint).max);
        bribes[_gauge] = _bribe;
        gauges[_pair] = _gauge;
        poolForGauge[_gauge] = _pair;
        isGauge[_gauge] = true;
        isLive[_gauge] = true;
        isReward[_gauge][_tokenA] = true;
        isReward[_gauge][_tokenB] = true;
        isReward[_gauge][base] = true;
        isBribe[_bribe][_tokenA] = true;
        isBribe[_bribe][_tokenB] = true;
        _updateFor(_gauge);
        allGauges.push(_gauge);
        emit GaugeCreated(_gauge, msg.sender, _bribe, _pair);
        return _gauge;
    }

    function attachTokenToGauge(uint tokenId, address account) external {
        require(isGauge[msg.sender]);
        if (tokenId > 0) IVotingEscrow(_ve).attach(tokenId);
        emit Attach(account, msg.sender, tokenId);
    }

    function emitDeposit(uint tokenId, address account, uint amount) external {
        require(isGauge[msg.sender]);
        emit Deposit(account, msg.sender, tokenId, amount);
    }

    function detachTokenFromGauge(uint tokenId, address account) external {
        require(isGauge[msg.sender]);
        if (tokenId > 0) IVotingEscrow(_ve).detach(tokenId);
        emit Detach(account, msg.sender, tokenId);
    }

    function emitWithdraw(uint tokenId, address account, uint amount) external {
        require(isGauge[msg.sender]);
        emit Withdraw(account, msg.sender, tokenId, amount);
    }

    function length() external view returns (uint) {
        return allGauges.length;
    }

    // @notice called by Minter contract to distribute weekly rewards
    // @param _amount the amount of tokens distributed
    function notifyRewardAmount(uint amount) external {
        _safeTransferFrom(base, msg.sender, address(this), amount); // transfer the distro in
        uint256 _ratio = amount * 1e18 / totalWeight; // 1e18 adjustment is removed during claim
        if (_ratio > 0) {
            index += _ratio;
        }
        emit NotifyReward(msg.sender, base, amount);
    }

    function updateFor(address[] memory _gauges) external {
        for (uint i = 0; i < _gauges.length; i++) {
            _updateFor(_gauges[i]);
        }
    }

    function updateForRange(uint start, uint end) public {
        for (uint i = start; i < end; i++) {
            _updateFor(allGauges[i]);
        }
    }

    function updateAll() external {
        updateForRange(0, allGauges.length);
    }

    // @notice update a gauge eligibility for rewards to the current index
    // @param _gauge the gauge to update
    function updateGauge(address _gauge) external {
        _updateFor(_gauge);
    }

    function _updateFor(address _gauge) internal {
        uint256 _supplied = weights[_gauge];
        if (_supplied > 0) {
            uint _supplyIndex = supplyIndex[_gauge];
            uint _index = index; // get global index0 for accumulated distro
            supplyIndex[_gauge] = _index; // update _gauge current position to global position
            uint _delta = _index - _supplyIndex; // see if there is any difference that need to be accrued
            if (_delta > 0) {
                uint _share = uint(_supplied) * _delta / 1e18; // add accrued difference for each supplied token
                if (isLive[_gauge]) {
                    claimable[_gauge] += _share;
                }
            }
        } else {
            supplyIndex[_gauge] = index; // new users are set to the default global state
        }
    }

    // @notice allow a gauge depositor to claim earned rewards if any
    // @param _gauges list of gauges contracts to claim rewards on
    // @param _tokens list of  tokens to claim
    function claimRewards(address[] memory _gauges, address[][] memory _tokens) external {
        for (uint i = 0; i < _gauges.length; i++) {
            try IGauge(_gauges[i]).getReward(msg.sender, _tokens[i]) {
                
            } catch {
                emit ErrorClaimingGaugeRewards(_gauges[i], _tokens[i]);
            }
        }
    }

    // @notice allow a voter to claim earned bribes if any
    // @param _bribes list of bribes contracts to claims bribes on
    // @param _tokens list of the tokens to claim
    // @param _tokenId the ID of veNFT to claim bribes for
    function claimBribes(address[] memory _bribes, address[][] memory _tokens, uint _tokenId) external {
        require(IVotingEscrow(_ve).isApprovedOrOwner(msg.sender, _tokenId));
        for (uint i = 0; i < _bribes.length; i++) {
            try IBribe(_bribes[i]).getRewardForOwner(_tokenId, _tokens[i]) {
                
            } catch {
                emit ErrorClaimingBribeRewards(_bribes[i], _tokens[i]);
            }
        }
    }

    // @notice allow voter to claim earned fees
    // @param _fees list of bribes contracts to claim fees on
    // @param _tokens list of the tokens to claim
    // @param _tokenId the ID of veNFT to claim fees for
    function claimFees(address[] memory _fees, address[][] memory _tokens, uint _tokenId) external {
        require(IVotingEscrow(_ve).isApprovedOrOwner(msg.sender, _tokenId));
        for (uint i = 0; i < _fees.length; i++) {
            try IBribe(_fees[i]).getRewardForOwner(_tokenId, _tokens[i]) {
                
            } catch {
                emit ErrorClaimingBribeFees(_fees[i], _tokenId, _tokens[i]);
            }
        }
    }

    // @notice distribute earned fees to the bribe contract for a given gauge
    // @param _gauges the gauges to distribute fees for
    function distributeFees(address[] memory _gauges) external {
        for (uint i = 0; i < _gauges.length; i++) {
            try IGauge(_gauges[i]).claimFees() {
                
            } catch {
                emit ErrorClaimingGaugeFees(_gauges[i]);
            }
        }
    }

    // @notice distribute earned fees to the bribe contract for all gauges
    function distroFees() external {
        for (uint i = 0; i < allGauges.length; i++) {
            try IGauge(allGauges[i]).claimFees() {
                
            } catch {
                emit ErrorClaimingGaugeFees(allGauges[i]);
            }
        }
    }

    // @notice distribute fair share of rewards to a gauge
    // @param _gauge the gauge to distribute rewards to
    function distribute(address _gauge) public lock {
        IMinter(minter).update_period();
        _updateFor(_gauge);
        uint _claimable = claimable[_gauge];
        if (_claimable > IGauge(_gauge).left(base) && _claimable / DURATION > 0) {
            claimable[_gauge] = 0;
            IGauge(_gauge).notifyRewardAmount(base, _claimable);
            emit DistributeReward(msg.sender, _gauge, _claimable);
        }
    }

    function distro() external {
        distributeRange(0, allGauges.length);
    }

    function distributeRange(uint start, uint finish) public {
        for (uint x = start; x < finish; x++) {
            try this.distribute(allGauges[x]) {
                emit GaugeProcessed(allGauges[x]);
            } catch {
                emit GaugeNotProcessed(allGauges[x]);
            }
        }
    }

    function distributeGauges(address[] memory _gauges) external {
        for (uint x = 0; x < _gauges.length; x++) {
            try this.distribute(_gauges[x]) {
                emit GaugeProcessed(allGauges[x]);
            } catch {
                emit GaugeNotProcessed(allGauges[x]);
            }
        }
    }

    // @notice current active vote period
    // @return the UNIX timestamp of the beginning of the current vote period
    function _activePeriod() internal view returns (uint activePeriod) {
        activePeriod = block.timestamp / DURATION * DURATION;
    }

    // @notice next vote period
    // @return the UNIX timestamp of the beginning of the next vote period
    function _nextPeriod() internal view returns(uint nextPeriod) {
        nextPeriod = (block.timestamp + DURATION) / DURATION * DURATION;
    }

    function _safeTransferFrom(address token, address from, address to, uint256 value) internal {
        require(token.code.length > 0);
        (bool success, bytes memory data) =
        token.call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))));
    }
}