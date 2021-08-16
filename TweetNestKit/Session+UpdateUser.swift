//
//  Session+UpdateUser.swift
//  Session+UpdateUser
//
//  Created by Jaehong Kang on 2021/08/06.
//

import Foundation
import CoreData
import OrderedCollections
import UnifiedLogging
import Twitter
import SwiftUI

extension Session {
    public nonisolated func updateUsers<C>(ids userIDs: C, with twitterSession: Twitter.Session) async throws where C: Collection, C.Index == Int, C.Element == Twitter.User.ID {
        let userIDs = OrderedSet(userIDs)

        return try await withThrowingTaskGroup(of: (Date, [Twitter.User], Date).self) { chunkedUsersTaskGroup in
            for chunkedUserIDs in userIDs.chunked(into: 100) {
                chunkedUsersTaskGroup.addTask {
                    let startDate = Date()
                    let users = try await [Twitter.User](ids: chunkedUserIDs, session: twitterSession)
                    let endDate = Date()

                    return (startDate, users, endDate)
                }
            }

            return try await withThrowingTaskGroup(of: Void.self) { taskGroup in
                let context = container.newBackgroundContext()
                context.undoManager = nil

                for try await chunkedUsers in chunkedUsersTaskGroup {
                    for user in chunkedUsers.1 {
                        taskGroup.addTask {
                            try await context.perform(schedule: .enqueued) {
                                let userData = try UserData.createOrUpdate(
                                    twitterUser: user,
                                    userUpdateStartDate: chunkedUsers.0,
                                    userDataCreationDate: chunkedUsers.2,
                                    context: context
                                )

                                if userData.user?.account != nil {
                                    // Don't update user data if user data has account. (Might overwrite followings/followers list)
                                    context.delete(userData)
                                }

                                if context.hasChanges {
                                    try context.save()
                                }
                            }
                        }

                        taskGroup.addTask {
                            do {
                                _ = try await DataAsset.dataAsset(for: user.profileImageOriginalURL, session: self, context: context)
                            } catch {
                                Logger(subsystem: Bundle.module.bundleIdentifier!, category: "fetch-profile-image")
                                    .error("Error occurred while downloading image: \(String(reflecting: error), privacy: .public)")
                            }

                            try await context.perform(schedule: .enqueued) {
                                if context.hasChanges {
                                    try context.save()
                                }
                            }
                        }
                    }
                }

                try await taskGroup.waitForAll()
            }
        }
    }
}
