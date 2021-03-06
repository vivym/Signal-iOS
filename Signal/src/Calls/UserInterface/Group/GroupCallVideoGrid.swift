//
//  Copyright (c) 2020 Open Whisper Systems. All rights reserved.
//

import Foundation
import SignalRingRTC

class GroupCallVideoGrid: UICollectionView {
    let layout: GroupCallVideoGridLayout
    let call: SignalCall
    init(call: SignalCall) {
        self.call = call
        self.layout = GroupCallVideoGridLayout()

        super.init(frame: .zero, collectionViewLayout: layout)

        call.addObserverAndSyncState(observer: self)
        layout.delegate = self

        register(GroupCallVideoGridCell.self, forCellWithReuseIdentifier: GroupCallVideoGridCell.reuseIdentifier)
        dataSource = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit { call.removeObserver(self) }
}

extension GroupCallVideoGrid: UICollectionViewDataSource {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return min(maxItems, call.groupCall.remoteDeviceStates.count)
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: GroupCallVideoGridCell.reuseIdentifier,
            for: indexPath
        ) as! GroupCallVideoGridCell

        guard let remoteDevice = call.groupCall.sortedRemoteDeviceStates[safe: indexPath.row] else {
            owsFailDebug("missing member address")
            return cell
        }

        cell.configure(call: call, device: remoteDevice)

        return cell
    }
}

extension GroupCallVideoGrid: CallObserver {
    func groupCallLocalDeviceStateChanged(_ call: SignalCall) {}

    func groupCallRemoteDeviceStatesChanged(_ call: SignalCall) {
        AssertIsOnMainThread()
        owsAssertDebug(call.isGroupCall)

        reloadData()
    }

    func groupCallJoinedMembersChanged(_ call: SignalCall) {
        AssertIsOnMainThread()
        owsAssertDebug(call.isGroupCall)

        reloadData()
    }

    func groupCallEnded(_ call: SignalCall, reason: GroupCallEndReason) {}

    func groupCallRequestMembershipProof(_ call: SignalCall) {}
    func groupCallRequestGroupMembers(_ call: SignalCall) {}

    func individualCallStateDidChange(_ call: SignalCall, state: CallState) {}
    func individualCallLocalVideoMuteDidChange(_ call: SignalCall, isVideoMuted: Bool) {}
    func individualCallLocalAudioMuteDidChange(_ call: SignalCall, isAudioMuted: Bool) {}
    func individualCallRemoteVideoMuteDidChange(_ call: SignalCall, isVideoMuted: Bool) {}
    func individualCallHoldDidChange(_ call: SignalCall, isOnHold: Bool) {}
}

extension GroupCallVideoGrid: GroupCallVideoGridLayoutDelegate {
    var maxColumns: Int {
        if CurrentAppContext().frame.width > 1080 {
            return 4
        } else if CurrentAppContext().frame.width > 768 {
            return 3
        } else {
            return 2
        }
    }

    var maxRows: Int {
        if CurrentAppContext().frame.height > 1024 {
            return 4
        } else {
            return 3
        }
    }

    var maxItems: Int { maxColumns * maxRows }

    func deviceState(for index: Int) -> RemoteDeviceState? {
        return call.groupCall.sortedRemoteDeviceStates[safe: index]
    }
}

class GroupCallVideoGridCell: UICollectionViewCell {
    static let reuseIdentifier = "GroupCallVideoGridCell"
    private let memberView = GroupCallRemoteMemberView()

    override init(frame: CGRect) {
        super.init(frame: frame)

        contentView.addSubview(memberView)
        memberView.autoPinEdgesToSuperviewEdges()

        contentView.layer.cornerRadius = 10
        contentView.clipsToBounds = true
    }

    func configure(call: SignalCall, device: RemoteDeviceState) {
        memberView.configure(call: call, device: device)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

extension GroupCall {
    var sortedRemoteDeviceStates: [RemoteDeviceState] {
        return remoteDeviceStates
            .values
            .sorted { $0.speakerIndex ?? .max < $1.speakerIndex ?? .max }
    }
}
