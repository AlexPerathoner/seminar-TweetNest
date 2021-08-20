//
//  DeleteBulkTweetsAllTweetsView.swift
//  DeleteBulkTweetsAllTweetsView
//
//  Created by Jaehong Kang on 2021/08/18.
//

import SwiftUI
import UnifiedLogging
import TweetNestKit
import Twitter

struct DeleteBulkTweetsAllTweetsView: View {
    let account: TweetNestKit.Account
    
    @Binding var isPresented: Bool
    
    @State var tweets: [Tweet]? = nil
    
    @State var isFileImporterPresented: Bool = false
    
    @State var isImporting: Bool = false
    
    @State var showError: Bool = false
    @State var error: TweetNestError? = nil
    
    var body: some View {
        ZStack {
            if let tweets = tweets {
                Rectangle()
                    .foregroundColor(.clear)
                    .overlay {
                        DeleteBulkTweetsFormView(tweets: tweets, isPresented: $isPresented)
                            .environment(\.account, account)
                    }
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
                    .zIndex(3)
            } else if isImporting {
                Rectangle()
                    .foregroundColor(.clear)
                    .overlay {
                        ProgressView("Loading Archive...")
                            .alert(isPresented: $showError, error: error)
                            .toolbar {
                                ToolbarItemGroup(placement: .cancellationAction) {
                                    Button(role: .cancel) {
                                        isPresented = false
                                    } label: {
                                        Text("Cancel")
                                    }
                                }
                            }
                    }
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
                    .zIndex(2)
            } else {
                Rectangle()
                    .foregroundColor(.clear)
                    .overlay {
                        Button {
                            isFileImporterPresented = true
                        } label: {
                            Text("Open Twitter Archive")
                        }
                        .toolbar {
                            ToolbarItemGroup(placement: .cancellationAction) {
                                Button(role: .cancel) {
                                    isPresented = false
                                } label: {
                                    Text("Cancel")
                                }
                            }
                        }
                        .fileImporter(isPresented: $isFileImporterPresented, allowedContentTypes: [.folder], onCompletion: onFileImporterCompletion(result:))
                    }
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
                    .zIndex(1)
            }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationTitle(Text("Delete Tweets"))
        .navigationBarBackButtonHidden(true)
    }
    
    func onFileImporterCompletion(result: Result<URL, Error>) {
        withAnimation {
            isImporting = true
        }
        
        Task {
            do {
                let url = try result.get()
                
                _ = url.startAccessingSecurityScopedResource()
                defer {
                    url.stopAccessingSecurityScopedResource()
                }
                
                let twitterArchive = TwitterArchive(url: url)
                
                let tweets = try await twitterArchive.tweets
                
                withAnimation {
                    self.tweets = tweets
                }
            } catch {
                Logger().error("Error: \(error as NSError)")
                self.error = TweetNestError(error)
                showError = true
            }
        }
    }
}

struct DeleteBulkTweetsAllTweetsView_Previews: PreviewProvider {
    static var previews: some View {
        DeleteBulkTweetsAllTweetsView(account: .preview, isPresented: .constant(true))
    }
}