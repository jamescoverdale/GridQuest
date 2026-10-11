# GridQuest

An iPhone app that turns Apple Health workout routes into collected map squares, using the grid verified in Squadra by Bert Temme.

- [iOS app and verification](ios/GridQuest/README.md)
- [Static information website](website/README.md)
- [App icon artwork and generation prompt](docs/app-icon.md)

The local checkout includes `ios/GridQuest/GridQuest.xcodeproj` for running the app in Xcode. Its account-specific project configuration is kept locally and excluded from Git; a fresh clone needs an iOS Xcode project configured with the included app and test sources, assets and HealthKit entitlement. The website is a standalone static site with its files in `website/dist/`.
