const path = require('path')
const { getDefaultConfig } = require('@react-native/metro-config')
const { getConfig } = require('react-native-builder-bob/metro-config')

const root = path.resolve(__dirname, '..')
const pkg = require('../package.json')

/**
 * Resolves the library from its TypeScript source, so edits show up without a rebuild.
 */
module.exports = getConfig(getDefaultConfig(__dirname), {
  root,
  pkg,
  project: __dirname,
})
