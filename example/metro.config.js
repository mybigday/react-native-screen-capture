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
    // Metro warns on every start that the `exports` target under `lib` does not exist -- it is
    // blocked just above -- and then falls back to file-based resolution, which lands on `src`.
    // The warning is noise; the resolution is correct.
    //
    // Do NOT "fix" it with `unstable_conditionNames: ['source', ...]`. That condition list is
    // global, so it changes resolution for every package, not just this one, and it breaks the
    // app at startup with `[runtime not ready] TypeError: ... is not a function`. Confirmed on
    // an iPhone: reverting this line is what made the app boot again.
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
