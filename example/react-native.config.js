const path = require('path')
const pkg = require('../package.json')

// Autolink the library straight from the parent directory instead of node_modules.
module.exports = {
  dependencies: {
    [pkg.name]: {
      root: path.join(__dirname, '..'),
    },
  },
}
