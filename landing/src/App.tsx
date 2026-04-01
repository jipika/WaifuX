import Beams from './components/Beams/Beams';
import { Download, Search, Sparkles, Film, RefreshCw, Settings, Mountain, Play, Tv, Ghost } from 'lucide-react';

const GithubIcon = ({ className }: { className?: string }) => (
  <svg className={className} viewBox="0 0 24 24" fill="currentColor">
    <path d="M12 0c-6.626 0-12 5.373-12 12 0 5.302 3.438 9.8 8.207 11.387.599.111.793-.261.793-.577v-2.234c-3.338.726-4.033-1.416-4.033-1.416-.546-1.387-1.333-1.756-1.333-1.756-1.089-.745.083-.729.083-.729 1.205.084 1.839 1.237 1.839 1.237 1.07 1.834 2.807 1.304 3.492.997.107-.775.418-1.305.762-1.604-2.665-.305-5.467-1.334-5.467-5.931 0-1.311.469-2.381 1.236-3.221-.124-.303-.535-1.524.117-3.176 0 0 1.008-.322 3.301 1.23.957-.266 1.983-.399 3.003-.404 1.02.005 2.047.138 3.006.404 2.291-1.552 3.297-1.23 3.297-1.23.653 1.653.242 2.874.118 3.176.77.84 1.235 1.911 1.235 3.221 0 4.609-2.807 5.624-5.479 5.921.43.372.823 1.102.823 2.222v3.293c0 .319.192.694.801.576 4.765-1.589 8.199-6.086 8.199-11.386 0-6.627-5.373-12-12-12z"/>
  </svg>
);

import './App.css';

function App() {
  return (
    <div className="app">
      <Beams 
        beamWidth={2}
        beamHeight={20}
        beamNumber={15}
        lightColor="#ffffff"
        speed={2}
        noiseIntensity={1.5}
        scale={0.15}
      />

      <div className="relative w-full h-full overflow-hidden pointer-events-none">
        <div className="pointer-events-none">
          {/* Navbar - following the demo structure */}
          <div className="top-[2em] left-0 z-10 absolute flex justify-between items-center glass-nav mx-auto my-0 px-6 py-4 border border-white/20 rounded-[50px] w-[90%] md:w-[60%]">
            <img src="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><rect fill='%236366f1' width='100' height='100' rx='20'/><text y='.9em' font-size='60' x='50%' text-anchor='middle' fill='white' font-family='system-ui' font-weight='bold'>W</text></svg>" alt="WallHaven" className="h-[24px]" />
            <div className="hidden md:flex items-center gap-6 font-semibold">
              <a href="#features" className="text-[14px] text-white hover:text-gray-200 transition">功能特性</a>
              <a href="#sources" className="text-[14px] text-white hover:text-gray-200 transition">壁纸来源</a>
            </div>
            <a href="#download" className="text-[14px] text-white hover:text-gray-200 transition">下载</a>
          </div>

          {/* Center Content - matching demo structure */}
          <div className="top-0 left-0 z-10 absolute flex flex-col justify-center items-center w-full h-full pointer-events-none">
            <div className="flex justify-center items-center glass-tag px-4 border border-white/20 rounded-full w-auto h-[34px] font-medium text-white text-[12px] md:text-[14px]">
              <Sparkles className="w-3 h-3 mr-1" />
              <span>NEW</span>
            </div>
            
            <h1 className="mt-8 max-w-[18ch] font-bold text-white text-center leading-[1.2] tracking-[-2px] text-shadow" style="font-size: clamp(2rem, 4vw, 2.6rem); text-shadow: 0 0 16px rgba(0,0,0,0.5);">
              精美壁纸，<br />为你的桌面而生
            </h1>
            
            <div className="flex items-center gap-4 mt-8">
              <a href="https://github.com/jipika/WallHaven/releases/latest" target="_blank" className="demo-btn-primary">
                免费下载
              </a>
              <a href="https://github.com/jipika/WallHaven" target="_blank" className="demo-btn-secondary">
                查看源码
              </a>
            </div>
          </div>
        </div>
      </div>

      {/* Features Section */}
      <section id="features" className="section">
        <div className="container mx-auto px-6">
          <div className="flex flex-col lg:flex-row lg:items-end lg:justify-between mb-20">
            <div>
              <div className="flex items-center gap-4 mb-6">
                <div className="w-12 h-12 glass rounded-lg flex items-center justify-center">
                  <span className="font-bold text-indigo-500">01</span>
                </div>
                <span className="text-sm tracking-widest text-gray-500">功能特性</span>
              </div>
              <h2 className="text-5xl md:text-6xl font-bold text-white mb-4">强大的<br />壁纸管理</h2>
            </div>
            <p className="text-gray-400 max-w-md mt-4 lg:mt-0 text-lg">集成多种壁纸来源，一键切换，自动同步规则</p>
          </div>

          <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
            <div className="glass-card p-8 rounded-2xl">
              <div className="w-14 h-14 bg-indigo-500/20 rounded-xl flex items-center justify-center mb-6">
                <Search className="w-7 h-7 text-indigo-500" />
              </div>
              <h3 className="text-xl font-bold mb-3 text-white">智能搜索</h3>
              <p className="text-gray-400">支持关键词、标签、分类等多种搜索方式</p>
            </div>

            <div className="glass-card p-8 rounded-2xl">
              <div className="w-14 h-14 bg-cyan-500/20 rounded-xl flex items-center justify-center mb-6">
                <Sparkles className="w-7 h-7 text-cyan-400" />
              </div>
              <h3 className="text-xl font-bold mb-3 text-white">动态壁纸</h3>
              <p className="text-gray-400">支持 MotionBGs 动态视频壁纸</p>
            </div>

            <div className="glass-card p-8 rounded-2xl">
              <div className="w-14 h-14 bg-indigo-500/20 rounded-xl flex items-center justify-center mb-6">
                <Film className="w-7 h-7 text-indigo-500" />
              </div>
              <h3 className="text-xl font-bold mb-3 text-white">动漫解析</h3>
              <p className="text-gray-400">内置动漫视频解析功能</p>
            </div>

            <div className="glass-card p-8 rounded-2xl">
              <div className="w-14 h-14 bg-cyan-500/20 rounded-xl flex items-center justify-center mb-6">
                <RefreshCw className="w-7 h-7 text-cyan-400" />
              </div>
              <h3 className="text-xl font-bold mb-3 text-white">自动同步</h3>
              <p className="text-gray-400">GitHub 规则自动同步</p>
            </div>

            <div className="glass-card p-8 rounded-2xl">
              <div className="w-14 h-14 bg-indigo-500/20 rounded-xl flex items-center justify-center mb-6">
                <Download className="w-7 h-7 text-indigo-500" />
              </div>
              <h3 className="text-xl font-bold mb-3 text-white">一键下载</h3>
              <p className="text-gray-400">高清壁纸一键保存</p>
            </div>

            <div className="glass-card p-8 rounded-2xl">
              <div className="w-14 h-14 bg-cyan-500/20 rounded-xl flex items-center justify-center mb-6">
                <Settings className="w-7 h-7 text-cyan-400" />
              </div>
              <h3 className="text-xl font-bold mb-3 text-white">自定义规则</h3>
              <p className="text-gray-400">支持自定义解析规则</p>
            </div>
          </div>
        </div>
      </section>

      {/* Sources Section */}
      <section id="sources" className="section">
        <div className="container mx-auto px-6">
          <div className="text-center mb-20">
            <div className="flex items-center justify-center gap-4 mb-6">
              <div className="w-12 h-px bg-gradient-to-r from-transparent to-indigo-500"></div>
              <span className="text-sm tracking-widest text-gray-500">壁纸来源</span>
              <div className="w-12 h-px bg-gradient-to-l from-transparent to-indigo-500"></div>
            </div>
            <h2 className="text-5xl md:text-6xl font-bold text-white mb-6">丰富的内容来源</h2>
            <p className="text-gray-400 text-lg max-w-2xl mx-auto">支持多种壁纸源，持续更新扩展</p>
          </div>

          <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
            <div className="source-card p-10 rounded-2xl">
              <div className="w-16 h-16 glass rounded-xl flex items-center justify-center mb-6">
                <Mountain className="w-8 h-8 text-indigo-500" />
              </div>
              <h3 className="text-2xl font-bold text-white mb-3">WALLHAVEN</h3>
              <p className="text-gray-400 leading-relaxed mb-6">海量高清静态壁纸库</p>
              <div className="flex flex-wrap gap-2">
                <span className="tag">4K</span>
                <span className="tag">分类丰富</span>
              </div>
            </div>

            <div className="source-card p-10 rounded-2xl">
              <div className="w-16 h-16 glass rounded-xl flex items-center justify-center mb-6">
                <Play className="w-8 h-8 text-cyan-400" />
              </div>
              <h3 className="text-2xl font-bold text-white mb-3">MOTIONBGS</h3>
              <p className="text-gray-400 leading-relaxed mb-6">精选动态视频壁纸</p>
              <div className="flex flex-wrap gap-2">
                <span className="tag">动态</span>
                <span className="tag">视频</span>
              </div>
            </div>

            <div className="source-card p-10 rounded-2xl">
              <div className="w-16 h-16 glass rounded-xl flex items-center justify-center mb-6">
                <Tv className="w-8 h-8 text-indigo-500" />
              </div>
              <h3 className="text-2xl font-bold text-white mb-3">动漫视频</h3>
              <p className="text-gray-400 leading-relaxed mb-6">多种动漫源解析</p>
              <div className="flex flex-wrap gap-2">
                <span className="tag">动漫</span>
                <span className="tag">多源</span>
              </div>
            </div>
          </div>
        </div>
      </section>

      {/* CTA Section */}
      <section id="download" className="section cta-section">
        <div className="absolute inset-0 pointer-events-none">
          <div className="absolute top-1/2 left-1/2 -translate-x-1/2 -translate-y-1/2 w-[600px] h-[600px] bg-indigo-500/10 rounded-full blur-[100px]"></div>
        </div>

        <div className="container mx-auto px-6 relative z-10">
          <div className="max-w-4xl mx-auto text-center">
            <h2 className="text-5xl md:text-6xl lg:text-7xl font-bold text-white mb-8">开始探索</h2>
            <p className="text-gray-400 text-xl mb-12 max-w-2xl mx-auto">免费下载 WallHaven，让你的 macOS 桌面焕然一新</p>

            <div className="flex flex-col sm:flex-row items-center justify-center gap-6">
              <a href="https://github.com/jipika/WallHaven/releases" target="_blank" className="btn-primary text-lg px-10 py-5 glow-purple">
                <Download className="w-6 h-6" />
                下载最新版本
              </a>
              <a href="https://github.com/jipika/WallHaven" target="_blank" className="btn-secondary text-lg px-10 py-5">
                <GithubIcon className="w-6 h-6" />
                STAR ON GITHUB
              </a>
            </div>
          </div>
        </div>
      </section>

      {/* Footer */}
      <footer className="footer">
        <div className="container mx-auto px-6">
          <div className="grid grid-cols-12 gap-8">
            <div className="col-span-12 lg:col-span-4">
              <div className="flex items-center gap-3 mb-6">
                <div className="w-10 h-10 bg-gradient-to-br from-indigo-500 to-cyan-400 rounded-lg flex items-center justify-center">
                  <span className="font-bold text-white text-lg">W</span>
                </div>
                <span className="font-bold text-xl">WALLHAVEN</span>
              </div>
              <p className="text-gray-500 text-sm leading-relaxed">
                macOS 壁纸应用<br />
                支持 WallHaven、MotionBGs 和动漫视频
              </p>
            </div>

            <div className="col-span-12 lg:col-span-4 lg:col-start-6 mt-12 lg:mt-0">
              <h4 className="font-bold mb-6 text-white">LINKS</h4>
              <div className="space-y-3">
                <a href="https://github.com/jipika/WallHaven" target="_blank" className="block text-gray-500 hover:text-white transition-colors">GitHub</a>
                <a href="https://github.com/jipika/WallHaven-Profiles" target="_blank" className="block text-gray-500 hover:text-white transition-colors">规则仓库</a>
              </div>
            </div>

            <div className="col-span-12 lg:col-span-2 lg:col-start-10 mt-12 lg:mt-0">
              <h4 className="font-bold mb-6 text-white">INFO</h4>
              <p className="text-gray-500 text-sm">
                © 2026 WallHaven<br />
                MIT 协议开源
              </p>
            </div>
          </div>
        </div>
      </footer>
    </div>
  );
}

export default App;