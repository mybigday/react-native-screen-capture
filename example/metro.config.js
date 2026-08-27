const path = require('path')
const { getDefaultConfig, mergeConfig } = require('@react-native/metro-config')

const root = path.resolve(__dirname, '..')
const pkg = require('../package.json')

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

/**
 * Resolve the library from its TypeScript source so edits show up without a rebuild.
 *
 * The repo root is a publishable package and yarn 1 only allows workspaces in private
 * projects, so this cannot use the usual builder-bob monorepo metro helper. Instead: watch
 * the root, map the package name onto it, and block the root's own node_modules and lib
 * outright -- otherwise Metro follows the symlink and resolves a second copy of
 * react/react-native from there, which fails with duplicate-module errors.
 */
const blocked = [path.join(root, 'node_modules'), path.join(root, 'lib')]
  .map((dir) => `${escapeRegExp(dir)}${escapeRegExp(path.sep)}.*`)
  .join('|')

const config = {
  watchFolders: [root],
  resolver: {
    blockList: new RegExp(`^(${blocked})$`),
    // `lib` is blocked above, but package.json `exports` still points there, so without this
    // Metro resolves the export, fails to find the file, and warns on every start. Preferring
    // the `source` condition sends it to src/index.ts directly, which is what we want anyway.
    unstable_conditionNames: ['source', 'react-native', 'require', 'import'],
    // Map the package name onto the repo root, and send everything else -- including the
    // @babel/runtime helpers Babel injects into the library's own source -- to the example's
    // node_modules, since the root's copy is blocked above.
    extraNodeModules: new Proxy(
      { [pkg.name]: root },
      {
        get: (target, name) =>
          typeof name === 'string' && name in target
            ? target[name]
            : path.join(__dirname, 'node_modules', String(name)),
      },
    ),
  },
}

module.exports = mergeConfig(getDefaultConfig(__dirname), config)
