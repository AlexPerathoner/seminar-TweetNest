//
//  UserAllDataSection.swift
//  UserAllDataSection
//
//  Created by Jaehong Kang on 2021/08/01.
//

import SwiftUI
import TweetNestKit

struct UserAllDataSection: View {
    private static let itemFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()
        
    let user: User

    @FetchRequest
    private var userDatas: FetchedResults<UserData>

    var body: some View {
        Section("All Data") {
            ForEach(userDatas) { userData in
                NavigationLink {
                    List {
                        Section {
                            UserProfileView(userData: userData)
                                .padding(8)
                        }

                        Section {
                            if let followingUserIDs = userData.followingUserIDs {
                                NavigationLink {
                                    UsersList(userIDs: followingUserIDs)
                                        .navigationTitle(Text("Followings (\(followingUserIDs.count))"))
                                } label: {
                                    Text("Followings (\(followingUserIDs.count))")
                                }
                            }

                            if let followerUserIDs = userData.followerUserIDs {
                                NavigationLink {
                                    UsersList(userIDs: followerUserIDs)
                                        .navigationTitle(Text("Followers (\(followerUserIDs.count))"))
                                } label: {
                                    Text("Followers (\(followerUserIDs.count))")
                                }
                            }
                        }
                    }
                    .navigationTitle(userData.creationDate.flatMap { Self.itemFormatter.string(from: $0) } ?? userData.objectID.description)
                } label: {
                    Text(userData.creationDate.flatMap { Self.itemFormatter.string(from: $0) } ?? userData.objectID.description)
                }
            }
        }
    }

    init(user: User) {
        self.user = user
        self._userDatas = FetchRequest(
            sortDescriptors: [NSSortDescriptor(keyPath: \User.creationDate, ascending: false)],
            predicate: NSPredicate(format: "user.id == %@", user.id),
            animation: .default
        )
    }
}

#if DEBUG
struct UserAllDataSection_Previews: PreviewProvider {
    static var previews: some View {
        UserAllDataSection(user: Account.preview.user!)
    }
}
#endif