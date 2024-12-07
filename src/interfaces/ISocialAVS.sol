// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ISocialAVS {
    function getSignal(uint64 blockFrom, uint64 blockTo) external view returns (int8 interestDelta);
}
