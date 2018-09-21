pragma solidity ^0.4.18;

import './Claimable.sol';
import './BravoCoin.sol';

/// @title Vesting trustee contract for Bravo coin.
contract BravoVestingTrustee is Claimable {
    using SafeMath for uint256;

    // The address of the BVO ERC20 token.
    BravoCoin public token;

    struct Grant {
        uint256 value;
        uint256 start;
        uint256 cliff;
        uint256 end;
        uint256 transferred;
        bool revokable;
    }

    // Grants holder.
    mapping (address => Grant[]) public grants;

    // Total tokens available for vesting.
    uint256 public totalVesting;

    event NewGrant(address indexed _from, address indexed _to, uint256 _value);
    event UnlockGrant(address indexed _holder, uint256 _value);
    event RevokeGrant(address indexed _holder, uint256 _refund);

    /// @dev Constructor that initializes the address of the SirnSmartToken contract.
    /// @param _token BravoCoin The address of the previously deployed SirnSmartToken smart contract.
    function BravoVestingTrustee(BravoCoin _token) {
        require(_token != address(0));

        token = _token;
    }

    /// @dev Grant tokens to a specified address.
    /// @param _to address The address to grant tokens to.
    /// @param _value uint256 The amount of tokens to be granted.
    /// @param _start uint256 The beginning of the vesting period.
    /// @param _cliff uint256 Duration of the cliff period.
    /// @param _end uint256 The end of the vesting period.
    /// @param _revokable bool Whether the grant is revokable or not.
    function grant(address _to, uint256 _value, uint256 _start, uint256 _cliff, uint256 _end, bool _revokable)
    public onlyOwner {
        require(_to != address(0));
        require(_value > 0);

        // Make sure that a single address can be granted tokens only once.
        // require(grants[_to].value == 0);

        // Check for date inconsistencies that may cause unexpected behavior.
        require(_start <= _cliff && _cliff <= _end);

        // Check that this grant doesn't exceed the total amount of tokens currently available for vesting.
        require(totalVesting.add(_value) <= token.balanceOf(address(this)));

        // Assign a new grant.
        Grant[] grantsForWallet = grants[_to];
        grantsForWallet.push(Grant({
            value: _value,
            start: _start,
            cliff: _cliff,
            end: _end,
            transferred: 0,
            revokable: _revokable
        }));
        
        // Tokens granted, reduce the total amount available for vesting.
        totalVesting = totalVesting.add(_value);

        NewGrant(msg.sender, _to, _value);
    }

    /// @dev Revoke the grant of tokens of a specifed address.
    /// @param _holder The address which will have its tokens revoked.
    function revoke(address _holder) public onlyOwner {
        Grant[] grant = grants[_holder];
        
        uint numberRevoked = 0;
        uint256 totalRefund = 0;
        for(uint i = 0; i < grant.length; i++) {
             if(!grant[i].revokable) continue;

            // Send the remaining STX back to the owner.
            uint256 refund = grant[i].value.sub(grant[i].transferred);
    
            totalVesting = totalVesting.sub(refund);
            numberRevoked++;
            totalRefund = totalRefund.add(refund);
        }
        
        if(numberRevoked == grant.length) {
            // Remove the grant.
            delete grants[_holder];
        }
        
        token.transfer(msg.sender, totalRefund);
        
        RevokeGrant(_holder, refund);
    }

    /// @dev Calculate the total amount of vested tokens of a holder at a given time.
    /// @param _holder address The address of the holder.
    /// @param _time uint256 The specific time.
    /// @return a uint256 representing a holder's total amount of vested tokens.
    function vestedTokens(address _holder, uint256 _time) public constant returns (uint256) {
        Grant[] grant = grants[_holder];
        
        return calculateVestedTokens(grant, _time);
    }

    /// @dev Calculate amount of vested tokens at a specifc time.
    /// @param _grant Grant The vesting grant.
    /// @param _time uint256 The time to be checked
    /// @return An uint256 representing the amount of vested tokens of a specific grant.
    ///   |                         _/--------   vestedTokens rect
    ///   |                       _/
    ///   |                     _/
    ///   |                   _/
    ///   |                 _/
    ///   |                /
    ///   |              .|
    ///   |            .  |
    ///   |          .    |
    ///   |        .      |
    ///   |      .        |
    ///   |    .          |
    ///   +===+===========+---------+----------> time
    ///     Start       Cliff      End
    function calculateVestedTokens(Grant[] _grant, uint256 _time) private constant returns (uint256) {
        // If we're before the cliff, then nothing is vested.
        uint256 vested = 0;
        for(uint i = 0; i < _grant.length; i++) {
            if (_time < _grant[i].cliff) {
                continue;
            }
    
            // If we're after the end of the vesting period - everything is vested;
            if (_time >= _grant[i].end) {
                vested = vested.add(_grant[i].value);
            } else {
                // Interpolate all vested tokens: vestedTokens = tokens/// (time - start) / (end - start)
                vested = vested.add(_grant[i].value.mul(_time.sub(_grant[i].start)).div(_grant[i].end.sub(_grant[i].start)));
            }
        }
        
        return vested;
    }

    function calculateVestedTokensForSpecificGrant(Grant _grant, uint256 _time) private constant returns (uint256) {
        // If we're before the cliff, then nothing is vested.
        if (_time < _grant.cliff) {
            return 0;
        }

        // If we're after the end of the vesting period - everything is vested;
        if (_time >= _grant.end) {
            return _grant.value;
        }

        // Interpolate all vested tokens: vestedTokens = tokens/// (time - start) / (end - start)
        return _grant.value.mul(_time.sub(_grant.start)).div(_grant.end.sub(_grant.start));
    }

    /// @dev Unlock vested tokens and transfer them to their holder.
    /// @return a uint256 representing the amount of vested tokens transferred to their holder.
    function unlockVestedTokens() public {
        Grant[] grant = grants[msg.sender];
        
        // Get the total amount of vested tokens, acccording to grant.
        uint256 vested = calculateVestedTokens(grant, now);
        if (vested == 0) {
            return;
        }
        
        
        // Make sure the holder doesn't transfer more than what he already has.
        uint256 transferable = 0;
        
        for(uint i = 0; i < grant.length; i++) {
            transferable = vested.sub(grant[i].transferred);
        }
        
        if (transferable == 0) {
            return;
        }
        
        
        for(uint j = 0; j < grant.length; i++) {
            grant[i].transferred = grant[j].transferred.add(calculateVestedTokensForSpecificGrant(grant[j], now));
            totalVesting = totalVesting.sub(grant[i].transferred);
        }
        
        token.transfer(msg.sender, transferable);

        UnlockGrant(msg.sender, transferable);
    }
}