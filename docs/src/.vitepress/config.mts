import { defineConfig } from 'vitepress'
import { tabsMarkdownPlugin } from 'vitepress-plugin-tabs'
import { withMermaid } from 'vitepress-plugin-mermaid'

export default withMermaid(defineConfig({
  base: '/Kaimon.jl/',
  title: 'Kaimon.jl',
  description: 'Opening the gate between AI and Julia',
  lastUpdated: true,
  cleanUrls: true,
  head: [['link', { rel: 'icon', href: '/Kaimon.jl/assets/kaimon_logo1.png' }]],

  markdown: {
    config(md) {
      md.use(tabsMarkdownPlugin)
    },
  },

  mermaid: {},

  themeConfig: {
    logo: '/assets/kaimon_logo1.png',
    nav: [
      { text: 'Guide', link: '/getting-started' },
      { text: 'Tools', link: '/tools' },
      { text: 'API', link: '/api' },
    ],

    sidebar: [
      {
        text: 'Introduction',
        items: [
          { text: 'Installation', link: '/installation' },
          { text: 'Getting Started', link: '/getting-started' },
          { text: 'Architecture', link: '/architecture' },
        ],
      },
      {
        text: 'Guide',
        items: [
          { text: 'Usage', link: '/usage' },
          { text: 'Tool Catalog', link: '/tools' },
          { text: 'The Gate', link: '/gate' },
          { text: 'Sessions', link: '/sessions' },
          { text: 'Semantic Search', link: '/search' },
          { text: 'Security', link: '/security' },
          { text: 'VS Code', link: '/vscode' },
          { text: 'Configuration', link: '/configuration' },
        ],
      },
      {
        text: 'Reference',
        items: [
          { text: 'API Reference', link: '/api' },
        ],
      },
    ],

    outline: {
      level: [2, 3],
    },

    search: {
      provider: 'local',
    },
    socialLinks: [
      { icon: 'github', link: 'https://github.com/kahliburke/Kaimon.jl' },
    ],
    footer: {
      message: 'Made with <a href="https://documenter.juliadocs.org/stable/">Documenter.jl</a> and <a href="https://vitepress.dev">VitePress</a>',
      copyright: 'Copyright © 2025-present',
    },
  },
}))
