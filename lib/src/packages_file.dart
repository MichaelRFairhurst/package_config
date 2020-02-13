// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import "package_config_impl.dart";

import "util.dart";
import "errors.dart";

/// Parses a `.packages` file into a [PackageConfig].
///
/// The [source] is the byte content of a `.packages` file, assumed to be
/// UTF-8 encoded. In practice, all significant parts of the file must be ASCII,
/// so Latin-1 or Windows-1252 encoding will also work fine.
///
/// If the file content is available as a string, its [String.codeUnits] can
/// be used as the `source` argument of this function.
///
/// The [baseLocation] is used as a base URI to resolve all relative
/// URI references against.
/// If the content was read from a file, `baseLocation` should be the
/// location of that file.
///
/// Returns a simple package configuration where each package's
/// [Package.packageUriRoot] is the same as its [Package.root]
/// and it has no [Package.languageVersion].
PackageConfig parse(
    List<int> source, Uri baseLocation, void onError(Object error)) {
  if (baseLocation.isScheme("package")) {
    onError(PackageConfigArgumentError(
        baseLocation, "baseLocation", "Must not be a package: URI"));
    return PackageConfig.empty;
  }
  int index = 0;
  List<Package> packages = [];
  Set<String> packageNames = {};
  while (index < source.length) {
    bool ignoreLine = false;
    int start = index;
    int separatorIndex = -1;
    int end = source.length;
    int char = source[index++];
    if (char == $cr || char == $lf) {
      continue;
    }
    if (char == $colon) {
      onError(PackageConfigFormatException(
          "Missing package name", source, index - 1));
      ignoreLine = true; // Ignore if package name is invalid.
    } else {
      ignoreLine = char == $hash; // Ignore if comment.
    }
    int queryStart = -1;
    int fragmentStart = -1;
    while (index < source.length) {
      char = source[index++];
      if (char == $colon && separatorIndex < 0) {
        separatorIndex = index - 1;
      } else if (char == $cr || char == $lf) {
        end = index - 1;
        break;
      } else if (char == $question && queryStart < 0 && fragmentStart < 0) {
        queryStart = index - 1;
      } else if (char == $hash && fragmentStart < 0) {
        fragmentStart = index - 1;
      }
    }
    if (ignoreLine) continue;
    if (separatorIndex < 0) {
      onError(
          PackageConfigFormatException("No ':' on line", source, index - 1));
      continue;
    }
    var packageName = String.fromCharCodes(source, start, separatorIndex);
    int invalidIndex = checkPackageName(packageName);
    if (invalidIndex >= 0) {
      onError(PackageConfigFormatException(
          "Not a valid package name", source, start + invalidIndex));
      continue;
    }
    if (queryStart >= 0) {
      onError(PackageConfigFormatException(
          "Location URI must not have query", source, queryStart));
      end = queryStart;
    } else if (fragmentStart >= 0) {
      onError(PackageConfigFormatException(
          "Location URI must not have fragment", source, fragmentStart));
      end = fragmentStart;
    }
    var packageValue = String.fromCharCodes(source, separatorIndex + 1, end);
    Uri packageLocation;
    try {
      packageLocation = baseLocation.resolve(packageValue);
    } on FormatException catch (e) {
      onError(PackageConfigFormatException.from(e));
      continue;
    }
    if (packageLocation.isScheme("package")) {
      onError(PackageConfigFormatException(
          "Package URI as location for package", source, separatorIndex + 1));
      continue;
    }
    if (!packageLocation.path.endsWith('/')) {
      packageLocation =
          packageLocation.replace(path: packageLocation.path + "/");
    }
    if (packageNames.contains(packageName)) {
      onError(PackageConfigFormatException(
          "Same package name occured more than once", source, start));
      continue;
    }
    var package = SimplePackage.validate(
        packageName, packageLocation, packageLocation, null, null, (error) {
      if (error is ArgumentError) {
        onError(PackageConfigFormatException(error.message, source));
      } else {
        onError(error);
      }
    });
    if (package != null) {
      packages.add(package);
      packageNames.add(packageName);
    }
  }
  return SimplePackageConfig(1, packages, null, onError);
}

/// Writes the configuration to a [StringSink].
///
/// If [comment] is provided, the output will contain this comment
/// with `# ` in front of each line.
/// Lines are defined as ending in line feed (`'\n'`). If the final
/// line of the comment doesn't end in a line feed, one will be added.
///
/// If [baseUri] is provided, package locations will be made relative
/// to the base URI, if possible, before writing.
///
/// If [allowDefaultPackage] is `true`, the [packageMapping] may contain an
/// empty string mapping to the _default package name_.
///
/// All the keys of [packageMapping] must be valid package names,
/// and the values must be URIs that do not have the `package:` scheme.
void write(StringSink output, PackageConfig config,
    {Uri baseUri, String comment}) {
  if (baseUri != null && !baseUri.isAbsolute) {
    throw PackageConfigArgumentError(baseUri, "baseUri", "Must be absolute");
  }

  if (comment != null) {
    var lines = comment.split('\n');
    if (lines.last.isEmpty) lines.removeLast();
    for (var commentLine in lines) {
      output.write('# ');
      output.writeln(commentLine);
    }
  } else {
    output.write("# generated by package:package_config at ");
    output.write(DateTime.now());
    output.writeln();
  }
  for (var package in config.packages) {
    var packageName = package.name;
    var uri = package.packageUriRoot;
    // Validate packageName.
    if (!isValidPackageName(packageName)) {
      throw PackageConfigArgumentError(
          config, "config", '"$packageName" is not a valid package name');
    }
    if (uri.scheme == "package") {
      throw PackageConfigArgumentError(
          config, "config", "Package location must not be a package URI: $uri");
    }
    output.write(packageName);
    output.write(':');
    // If baseUri is provided, make the URI relative to baseUri.
    if (baseUri != null) {
      uri = relativizeUri(uri, baseUri);
    }
    if (!uri.path.endsWith('/')) {
      uri = uri.replace(path: uri.path + '/');
    }
    output.write(uri);
    output.writeln();
  }
}