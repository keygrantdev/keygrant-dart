# KeyGrant for Flutter

The `keygrant` package licenses Flutter apps on iOS, iPadOS, Android, Windows, macOS and Linux with
[KeyGrant](https://keygrant.dev): signed leases verified offline, activation, trials and renewals, failing
in favour of the paying customer.

```sh
flutter pub add keygrant
```

How to use it is in [sdk-dart/README.md](sdk-dart/README.md), and the full guide is at
https://keygrant.dev/docs.

## Building from source

```sh
cd sdk-dart
flutter pub get
flutter test
```

The tests reproduce `conformance/vectors.json`, the behaviour every KeyGrant SDK shares.

## Releases

Each release is a version tag (`0.1.0`). The tag runs `.github/workflows/publish.yml`, which checks the
package and publishes it to pub.dev through pub.dev's automated publishing (the repository variable
`PUB_DEV_PUBLISHING` set to `on` switches the publish on; pub.dev takes a first version only by hand).

## License

MIT: see [LICENSE](LICENSE).
