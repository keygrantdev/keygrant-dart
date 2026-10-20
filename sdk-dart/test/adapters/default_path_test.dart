// Where the default storage keeps a product's state (the SDK contract,
// section 6; storage.test.ts `defaultStoragePath`; DefaultPathTests.swift).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:keygrant/src/core/defaults.dart';
import 'package:keygrant/src/core/storage.dart';
import 'package:keygrant/src/core/system_source.dart';

const String _winHome = r'C:\Users\jo';
const String _winDefault = r'C:\Users\jo\AppData\Local\KeyGrant\sluice.json';

void main() {
  final windows = <String, (Map<String, String>, String)>{
    'Windows': ({'LOCALAPPDATA': r'C:\Users\jo\AppData\Local'}, _winDefault),
    'Windows with %LOCALAPPDATA% elsewhere': ({'LOCALAPPDATA': r'D:\Profiles\jo\Local'}, r'D:\Profiles\jo\Local\KeyGrant\sluice.json'),
    'Windows with %LOCALAPPDATA% ending in a separator': ({'LOCALAPPDATA': 'D:\\Profiles\\jo\\Local\\'}, r'D:\Profiles\jo\Local\KeyGrant\sluice.json'),
    'Windows with %LOCALAPPDATA% on a share': ({'LOCALAPPDATA': r'\\server\jo\Local'}, r'\\server\jo\Local\KeyGrant\sluice.json'),
    // Roaming AppData follows the user to every machine of a domain.
    'Windows with only the roaming %APPDATA%': ({'APPDATA': r'C:\Users\jo\AppData\Roaming'}, _winDefault),
    'Windows with no %LOCALAPPDATA%': ({}, _winDefault),
    'Windows with an empty %LOCALAPPDATA%': ({'LOCALAPPDATA': ''}, _winDefault),
    'Windows with a relative %LOCALAPPDATA%': ({'LOCALAPPDATA': r'AppData\Local'}, _winDefault),
    'Windows with a drive-relative %LOCALAPPDATA%': ({'LOCALAPPDATA': 'C:Local'}, _winDefault),
  };
  for (final MapEntry(key: name, value: (env, expected)) in windows.entries) {
    test('keeps state per user on this machine on $name, never in the working directory', () {
      expect(defaultStoragePath('sluice', platform: 'win32', home: _winHome, env: env), expected);
    });
  }

  final posix = <String, (String, String, Map<String, String>, String)>{
    'macOS': ('darwin', '/Users/jo', {}, '/Users/jo/Library/Application Support/KeyGrant/sluice.json'),
    'macOS in a sandbox container': (
      'darwin',
      '/Users/jo/Library/Containers/com.example.app/Data',
      {},
      '/Users/jo/Library/Containers/com.example.app/Data/Library/Application Support/KeyGrant/sluice.json'
    ),
    'macOS, whatever XDG_CONFIG_HOME says': ('darwin', '/Users/jo', {'XDG_CONFIG_HOME': '/x'}, '/Users/jo/Library/Application Support/KeyGrant/sluice.json'),
    r'Linux with $XDG_CONFIG_HOME': ('linux', '/home/jo', {'XDG_CONFIG_HOME': '/home/jo/.cfg'}, '/home/jo/.cfg/keygrant/sluice.json'),
    'Linux with it ending in a slash': ('linux', '/home/jo', {'XDG_CONFIG_HOME': '/home/jo/.cfg/'}, '/home/jo/.cfg/keygrant/sluice.json'),
    'Linux without it': ('linux', '/home/jo', {}, '/home/jo/.config/keygrant/sluice.json'),
    'Linux with it empty': ('linux', '/home/jo', {'XDG_CONFIG_HOME': ''}, '/home/jo/.config/keygrant/sluice.json'),
    'Linux with it relative': ('linux', '/home/jo', {'XDG_CONFIG_HOME': '.cfg'}, '/home/jo/.config/keygrant/sluice.json'),
    'another system, as Linux': ('freebsd', '/home/jo', {}, '/home/jo/.config/keygrant/sluice.json'),
  };
  for (final MapEntry(key: name, value: (platform, home, env, expected)) in posix.entries) {
    test('keeps state per user on this machine on $name', () {
      expect(defaultStoragePath('sluice', platform: platform, home: home, env: env), expected);
    });
  }

  test('names the file for the product', () {
    expect(defaultStoragePath('maindeck', platform: 'linux', home: '/h', env: const {}), '/h/.config/keygrant/maindeck.json');
  });

  test('splits a path at its last separator, either kind', () {
    expect(splitPath(r'C:\Users\jo\sluice.json'), (dir: r'C:\Users\jo', name: 'sluice.json'));
    expect(splitPath('/home/jo/sluice.json'), (dir: '/home/jo', name: 'sluice.json'));
    expect(splitPath(r'C:\Users/jo\x.json'), (dir: r'C:\Users/jo', name: 'x.json'));
    expect(splitPath('sluice.json'), (dir: '.', name: 'sluice.json'));
  });

  test("this system's default path is in this user's folder, as section 6 names it", () {
    final env = Platform.environment;
    final path = defaultStoragePath('sluice', platform: nodePlatform(), home: env['USERPROFILE'] ?? env['HOME'] ?? '', env: env);
    expect(path, endsWith('${Platform.pathSeparator}sluice.json'));
    if (Platform.isWindows) expect(path, '${env['LOCALAPPDATA']}\\KeyGrant\\sluice.json');
    if (Platform.isMacOS) expect(path, contains('/Library/Application Support/KeyGrant/'));
    if (Platform.isLinux) expect(path, contains('/keygrant/'));
  });

  test('the default storage on a desktop is the file storage, and no phone is detected here', () {
    expect(isMobile, isFalse);
    expect(isDesktop, isTrue);
    expect(defaultStorage('sluice'), isA<FileStorage>());
  });
}
