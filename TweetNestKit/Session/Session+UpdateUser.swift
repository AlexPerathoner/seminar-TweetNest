//
//  Session+UpdateUser.swift
//  Session+UpdateUser
//
//  Created by Jaehong Kang on 2021/08/06.
//

import Foundation
import Algorithms
import BackgroundTask
import CoreData
import OrderedCollections
import UnifiedLogging
import Twitter
import TwitterV1
import SwiftUI

extension Session {
    public typealias UserDetailChanges = (oldUserDetailObjectID: NSManagedObjectID?, newUserDetailObjectID: NSManagedObjectID?)

    @discardableResult
    public func updateUsers<S>(
        ids userIDs: S,
        accountObjectID: NSManagedObjectID,
        context: NSManagedObjectContext? = nil
    ) async throws -> [Twitter.User.ID: UserDetailChanges] where S: Sequence, S.Element == Twitter.User.ID {
        let context = context ?? {
            let context = self.persistentContainer.newBackgroundContext()
            context.undoManager = nil

            return context
        }()

        let userIDs = Set(userIDs)

        let accountUserID: Twitter.User.ID? = try await context.perform {
            guard let account = context.object(with: accountObjectID) as? ManagedAccount else {
                throw SessionError.unknown
            }

            return account.userID
        }

        guard let accountUserID = accountUserID else {
            throw SessionError.unknown
        }

        async let accountUpdateResult = userIDs.contains(accountUserID) ? updateUser(accountObjectID: accountObjectID, context: context) : nil

        let twitterSession = try await self.twitterSession(for: accountObjectID)
        var updatingUsersResult = try await updateUsers(ids: userIDs.subtracting([accountUserID]), accountUserID: accountUserID, twitterSession: twitterSession, context: context)

        updatingUsersResult[accountUserID] = try await accountUpdateResult

        return updatingUsersResult
    }

    @discardableResult
    public func updateUser(
        accountObjectID: NSManagedObjectID,
        context: NSManagedObjectContext?
    ) async throws -> UserDetailChanges? {
        let context = context ?? {
            let context = self.persistentContainer.newBackgroundContext()
            context.undoManager = nil

            return context
        }()

        let (accountPreferences, accountUserID) = try await context.perform { () -> (ManagedAccount.Preferences, Twitter.User.ID?) in
            try withExtendedBackgroundExecution {
                guard let account = context.object(with: accountObjectID) as? ManagedAccount else {
                    throw SessionError.unknown
                }

                return (account.preferences, account.userID)
            }
        }

        guard let accountUserID = accountUserID else {
            throw SessionError.unknown
        }

        let twitterSession = try await self.twitterSession(for: accountObjectID)

        let (followingUserIDs, followerIDs, myBlockingUserIDs, myMutingUserIDs): ([Twitter.User.ID], [Twitter.User.ID], [Twitter.User.ID]?, [Twitter.User.ID]?) = try await withExtendedBackgroundExecution {
            async let followingUserIDs = try await Twitter.User.followingUserIDs(forUserID: accountUserID, session: twitterSession).userIDs
            async let followerIDs = try await Twitter.User.followerIDs(forUserID: accountUserID, session: twitterSession).userIDs
            async let myBlockingUserIDs = accountPreferences.fetchBlockingUsers ? try await Twitter.User.myBlockingUserIDs(session: twitterSession).userIDs : nil
            async let myMutingUserIDs = accountPreferences.fetchMutingUsers ? try await Twitter.User.myMutingUserIDs(session: twitterSession).userIDs : nil

            return try await (followingUserIDs, followerIDs, myBlockingUserIDs, myMutingUserIDs)
        }

        return try await self.updateUsers(
            ids: Set<Twitter.User.ID>([accountUserID] + [followingUserIDs, followerIDs, myBlockingUserIDs, myMutingUserIDs].compacted().joined()),
            accountUserID: accountUserID,
            twitterSession: twitterSession,
            addtionalUserInfos: [
                accountUserID: AdditionalUserInfo(
                    followingUserIDs: followingUserIDs,
                    followerIDs: followerIDs,
                    blockingUserIDs: myBlockingUserIDs,
                    mutingUserIDs: myMutingUserIDs
                )
            ],
            context: context
        )[accountUserID]
    }
}

extension Session {
    private struct AdditionalUserInfo {
        let followingUserIDs: [Twitter.User.ID]?
        let followerIDs: [Twitter.User.ID]?
        let blockingUserIDs: [Twitter.User.ID]?
        let mutingUserIDs: [Twitter.User.ID]?
    }

    private func updateUsers<S>(
        ids userIDs: S,
        accountUserID: Twitter.User.ID,
        twitterSession: Twitter.Session,
        addtionalUserInfos: [Twitter.User.ID: AdditionalUserInfo] = [:],
        context: NSManagedObjectContext
    ) async throws -> [Twitter.User.ID: UserDetailChanges] where S: Sequence, S.Element == Twitter.User.ID {
        try await withThrowingTaskGroup(of: ([TwitterV1.User], ClosedRange<Date>).self) { chunkedUsersFetchTaskGroup in
            let userObjectIDsByUserID = try await preflightUsersForUpdating(userIDs: userIDs, accountUserID: accountUserID, context: context)

            for chunkedUserIDs in userObjectIDsByUserID.keys.chunks(ofCount: 100) {
                chunkedUsersFetchTaskGroup.addTask {
                    let fetchStartDate = Date()

                    let users: [TwitterV1.User] = try await withExtendedBackgroundExecution {
                        if userObjectIDsByUserID.count == 1 && chunkedUserIDs.count == 1 {
                            return try await [TwitterV1.User(id: chunkedUserIDs[chunkedUserIDs.startIndex], session: twitterSession)]
                        } else {
                            return try await TwitterV1.User.users(ids: Array(chunkedUserIDs), session: twitterSession)
                        }
                    }

                    let fetchEndDate = Date()

                    return (users, fetchStartDate...fetchEndDate)
                }
            }

            return try await withThrowingTaskGroup(
                of: ([(Twitter.User.ID, UserDetailChanges)], [UserDataAssetsURLSessionManager.DownloadRequest]).self
            ) { chunkedUsersProcessingTaskGroup in
                for try await chunkedUsers in chunkedUsersFetchTaskGroup {
                    chunkedUsersProcessingTaskGroup.addTask {
                        try await withExtendedBackgroundExecution {
                            let chunkedUsersProcessingContext = NSManagedObjectContext(.privateQueue)
                            chunkedUsersProcessingContext.parent = context
                            chunkedUsersProcessingContext.automaticallyMergesChangesFromParent = true
                            chunkedUsersProcessingContext.undoManager = nil

                            let results = try await withThrowingTaskGroup(
                                of: (Twitter.User.ID, UserDetailChanges, [UserDataAssetsURLSessionManager.DownloadRequest]).self,
                                returning: ([(Twitter.User.ID, UserDetailChanges)], [UserDataAssetsURLSessionManager.DownloadRequest]).self
                            ) { userProcessingTaskGroup in
                                for twitterUser in chunkedUsers.0 {
                                    let userID = String(twitterUser.id)

                                    userProcessingTaskGroup.addTask {
                                        async let userDetailChanges: UserDetailChanges = chunkedUsersProcessingContext.perform(schedule: .enqueued) {
                                            let previousUserDetailFetchRequest = ManagedUserDetail.fetchRequest()
                                            previousUserDetailFetchRequest.predicate = NSPredicate(format: "userID == %@", userID)
                                            previousUserDetailFetchRequest.sortDescriptors = [
                                                NSSortDescriptor(keyPath: \ManagedUserDetail.creationDate, ascending: false)
                                            ]
                                            previousUserDetailFetchRequest.fetchLimit = 1
                                            previousUserDetailFetchRequest.returnsObjectsAsFaults = false

                                            let previousUserDetail = try chunkedUsersProcessingContext.fetch(previousUserDetailFetchRequest).first

                                            let userDetail = try ManagedUserDetail.createOrUpdate(
                                                twitterUser: twitterUser,
                                                followingUserIDs: addtionalUserInfos[userID]?.followingUserIDs,
                                                followerUserIDs: addtionalUserInfos[userID]?.followerIDs,
                                                blockingUserIDs: addtionalUserInfos[userID]?.blockingUserIDs,
                                                mutingUserIDs: addtionalUserInfos[userID]?.mutingUserIDs,
                                                creationDate: chunkedUsers.1.upperBound,
                                                previousUserDetail: previousUserDetail,
                                                context: chunkedUsersProcessingContext
                                            )

                                            return (previousUserDetail?.objectID, userDetail.objectID)
                                        }

                                        let downloadRequests = [
                                            twitterUser.profileImageOriginalURL.flatMap {
                                                UserDataAssetsURLSessionManager.DownloadRequest(url: $0, priority: URLSessionTask.defaultPriority, expectsToReceiveFileSize: 1 * 1024 * 1024)
                                            },
                                            twitterUser.profileBannerOriginalURL.flatMap {
                                                UserDataAssetsURLSessionManager.DownloadRequest(url: $0, priority: URLSessionTask.lowPriority, expectsToReceiveFileSize: 5 * 1024 * 1024)
                                            },
                                        ].compacted()

                                        return try await (userID, userDetailChanges, Array(downloadRequests))
                                    }
                                }

                                return try await userProcessingTaskGroup.reduce(
                                    into: ([(Twitter.User.ID, UserDetailChanges)](), [UserDataAssetsURLSessionManager.DownloadRequest]())
                                ) { partialResult, element in
                                    partialResult.0.append((element.0, element.1))
                                    partialResult.1.append(contentsOf: element.2)
                                }
                            }

                            try await context.perform(schedule: .enqueued) {
                                try chunkedUsersProcessingContext.performAndWait {
                                    guard chunkedUsersProcessingContext.hasChanges else {
                                        return
                                    }

                                    try chunkedUsersProcessingContext.save()
                                }

                                let userFetchRequest = ManagedUser.fetchRequest()
                                userFetchRequest.predicate = NSPredicate(format: "SELF IN %@", results.0.compactMap { userObjectIDsByUserID[$0.0] } )
                                userFetchRequest.propertiesToFetch = []
                                userFetchRequest.returnsObjectsAsFaults = false

                                let users = try context.fetch(userFetchRequest)

                                for user in users {
                                    user.lastUpdateEndDate = Date()
                                }

                                try context.save()
                            }

                            return results
                        }
                    }
                }

                var dataAssetsDownloadRequests = Set<UserDataAssetsURLSessionManager.DownloadRequest>()
                do {
                    let results = try await chunkedUsersProcessingTaskGroup.reduce(into: [Twitter.User.ID: UserDetailChanges]()) { totalResults, chunkedResults in
                        chunkedResults.0.forEach {
                            totalResults[$0.0] = $0.1
                        }

                        dataAssetsDownloadRequests.formUnion(chunkedResults.1)
                    }

                    await self.userDataAssetsURLSessionManager.download(dataAssetsDownloadRequests)

                    return results
                } catch {
                    await self.userDataAssetsURLSessionManager.download(dataAssetsDownloadRequests)

                    throw error
                }
            }
        }
    }

    private func preflightUsersForUpdating<S>(
        userIDs: S,
        accountUserID: String,
        context: NSManagedObjectContext
    ) async throws -> [Twitter.User.ID: NSManagedObjectID?] where S: Sequence, S.Element == Twitter.User.ID {
        try await context.perform { [userIDs = Set(userIDs)] in
            try withExtendedBackgroundExecution {
                let accountUserIDsfetchRequest = NSFetchRequest<NSDictionary>()
                accountUserIDsfetchRequest.entity = ManagedAccount.entity()
                accountUserIDsfetchRequest.resultType = .dictionaryResultType
                accountUserIDsfetchRequest.propertiesToFetch = ["userID"]
                accountUserIDsfetchRequest.returnsDistinctResults = true

                let results = try context.fetch(accountUserIDsfetchRequest)
                let allAccountUserIDs = Set(
                    results.compactMap {
                        $0["userID"] as? Twitter.User.ID
                    }
                )

                let userFetchRequest = ManagedUser.fetchRequest()
                userFetchRequest.predicate = NSPredicate(format: "id IN %@", userIDs)
                userFetchRequest.sortDescriptors = [
                    NSSortDescriptor(keyPath: \ManagedUser.creationDate, ascending: false)
                ]
                userFetchRequest.propertiesToFetch = ["lastUpdateStartDate"]
                userFetchRequest.returnsObjectsAsFaults = false

                let users = try context.fetch(userFetchRequest)
                let usersByID = Dictionary(
                    users.lazy.map { ($0.id, $0) },
                    uniquingKeysWith: { first, _ in first }
                )

                let refinedUserObjectIDByID: [Twitter.User.ID: NSManagedObjectID?] = Dictionary(
                    uniqueKeysWithValues: userIDs
                        .lazy
                        .compactMap { userID in
                            let user = usersByID[userID] ?? {
                                let user = ManagedUser(context: context)
                                user.id = userID
                                user.creationDate = Date()

                                return user
                            }()
                            let lastUpdateStartDate = user.lastUpdateStartDate ?? .distantPast

                            guard lastUpdateStartDate.addingTimeInterval(60) < Date() else {
                                return nil
                            }

                            // Don't update user data if user has account. (Might overwrite followings/followers list)
                            guard userID == accountUserID || allAccountUserIDs.contains(userID) == false else {
                                return nil
                            }

                            user.lastUpdateStartDate = Date()

                            return (userID, user.objectID)
                        }
                )

                if context.hasChanges {
                    context.perform {
                        do {
                            try withExtendedBackgroundExecution {
                                try context.save()
                            }
                        } catch {
                            Logger(label: Bundle.tweetNestKit.bundleIdentifier!, category: String(reflecting: Self.self))
                                .error("\(error as NSError, privacy: .public)")
                        }
                    }
                }

                return refinedUserObjectIDByID
            }
        }
    }
}
