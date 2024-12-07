// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Interface for IEigenLayerAVS social signal contract
interface IEigenLayerAVS {
    function getSignal(uint64 blockFrom, uint64 blockTo) external view returns (int8 interestDelta);
}

contract SocialAVSMock is IEigenLayerAVS {
    function getSignal(uint64 blockFrom, uint64 blockTo) external pure override returns (int8 interestDelta) {
        uint64 halfOfTotalBlocks = (blockTo - blockFrom) / 2;
        if (halfOfTotalBlocks > 127) {
            return 127;
        }
        return int8(int64(halfOfTotalBlocks));
    }
}
