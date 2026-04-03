import Beams from "./components/Beams/Beams"
import { Download, Search, Sparkles, Film, RefreshCw, Settings, Mountain, Play, Tv, Heart } from "lucide-react"
import { useLanguage } from "./contexts/LanguageContext"
import { LanguageSwitcher } from "./components/LanguageSwitcher"
import "./App.css"

const GithubIcon = ({ className }: { className?: string }) => (
    <svg className={className} viewBox="0 0 24 24" fill="currentColor">
        <path d="M12 0c-6.626 0-12 5.373-12 12 0 5.302 3.438 9.8 8.207 11.387.599.111.793-.261.793-.577v-2.234c-3.338.726-4.033-1.416-4.033-1.416-.546-1.387-1.333-1.756-1.333-1.756-1.089-.745.083-.729.083-.729 1.205.084 1.839 1.237 1.839 1.237 1.07 1.834 2.807 1.304 3.492.997.107-.775.418-1.305.762-1.604-2.665-.305-5.467-1.334-5.467-5.931 0-1.311.469-2.381 1.236-3.221-.124-.303-.535-1.524.117-3.176 0 0 1.008-.322 3.301 1.23.957-.266 1.983-.399 3.003-.404 1.02.005 2.047.138 3.006.404 2.291-1.552 3.297-1.23 3.297-1.23.653 1.653.242 2.874.118 3.176.77.84 1.235 1.911 1.235 3.221 0 4.609-2.807 5.624-5.479 5.921.43.372.823 1.102.823 2.222v3.293c0 .319.192.694.801.576 4.765-1.589 8.199-6.086 8.199-11.386 0-6.627-5.373-12-12-12z" />
    </svg>
)

function App() {
    const { t } = useLanguage()

    return (
        <div className="app">
            <Beams
                beamWidth={3}
                beamHeight={25}
                beamNumber={20}
                lightColor="#ffffff"
                speed={1.5}
                noiseIntensity={2}
                scale={0.12}
            />

            <div className="relative w-full min-h-screen">
                <nav className="top-[2em] left-0 z-10 absolute flex items-center glass-nav mx-auto my-0 px-6 py-4 border border-white/20 rounded-[50px] w-[90%] md:w-[70%] max-w-4xl">
                    <div className="flex items-center gap-3">
                        <span className="text-white font-bold text-base tracking-[0.2em]">WaifuX</span>
                    </div>

                    <div className="hidden md:flex items-center gap-6 font-semibold ml-auto">
                        <a href="#features" className="nav-link text-[14px] text-white/80 hover:text-white transition">
                            {t.nav.features}
                        </a>
                        <a href="#sources" className="nav-link text-[14px] text-white/80 hover:text-white transition">
                            {t.nav.sources}
                        </a>
                        <a href="#download" className="nav-link text-[14px] text-white/80 hover:text-white transition">
                            {t.nav.download}
                        </a>
                    </div>

                    <div className="flex items-center gap-4 ml-6">
                        <LanguageSwitcher />
                        <a
                            href="https://github.com/jipika/WaifuX"
                            target="_blank"
                            rel="noopener noreferrer"
                            className="hidden sm:flex items-center justify-center w-9 h-9 rounded-full bg-white/5 hover:bg-white/10 transition">
                            <GithubIcon className="w-[18px] h-[18px] text-white/80" />
                        </a>
                    </div>
                </nav>

                <section className="hero-section">
                    <div className="hero-content">
                        <div className="flex justify-center items-center glass-tag px-4 border border-white/20 rounded-full w-auto h-[34px] font-medium text-white text-[12px] md:text-[14px] animate-fade-in">
                            <Sparkles className="w-3 h-3 mr-2" />
                            <span>{t.hero.badge}</span>
                        </div>

                        <h1 className="hero-title">
                            {t.hero.title.split("\n").map((line, i) => (
                                <span key={i}>
                                    {line}
                                    {i < t.hero.title.split("\n").length - 1 && <br />}
                                </span>
                            ))}
                        </h1>

                        <p className="hero-subtitle">macOS 壁纸应用 · 支持 WallHaven、MotionBGs 和动漫视频</p>

                        <div className="hero-buttons">
                            <a
                                href="https://github.com/jipika/WaifuX/releases/latest"
                                target="_blank"
                                rel="noopener noreferrer"
                                className="btn-primary">
                                <Download className="w-5 h-5" />
                                {t.hero.downloadBtn}
                            </a>
                            <a
                                href="https://github.com/jipika/WaifuX"
                                target="_blank"
                                rel="noopener noreferrer"
                                className="btn-secondary">
                                <GithubIcon className="w-5 h-5" />
                                {t.hero.sourceBtn}
                            </a>
                        </div>
                    </div>
                </section>
            </div>

            {/* Features Section */}
            <section id="features" className="section">
                <div className="container mx-auto px-6">
                    <div className="section-header">
                        <div className="section-badge">
                            <div className="section-number">{t.features.sectionNumber}</div>
                            <span className="section-label">{t.features.sectionTitle}</span>
                        </div>
                        <h2 className="section-title">
                            {t.features.mainTitle.split("\n").map((line, i) => (
                                <span key={i}>
                                    {line}
                                    {i < t.features.mainTitle.split("\n").length - 1 && <br />}
                                </span>
                            ))}
                        </h2>
                        <p className="section-subtitle">{t.features.subtitle}</p>
                    </div>

                    <div className="features-grid">
                        <div className="feature-card">
                            <div className="feature-icon bg-indigo-500/20">
                                <Search className="w-7 h-7 text-indigo-400" />
                            </div>
                            <h3 className="feature-title">{t.features.cards.search.title}</h3>
                            <p className="feature-desc">{t.features.cards.search.desc}</p>
                        </div>

                        <div className="feature-card">
                            <div className="feature-icon bg-cyan-500/20">
                                <Sparkles className="w-7 h-7 text-cyan-400" />
                            </div>
                            <h3 className="feature-title">{t.features.cards.dynamic.title}</h3>
                            <p className="feature-desc">{t.features.cards.dynamic.desc}</p>
                        </div>

                        <div className="feature-card">
                            <div className="feature-icon bg-pink-500/20">
                                <Film className="w-7 h-7 text-pink-400" />
                            </div>
                            <h3 className="feature-title">{t.features.cards.anime.title}</h3>
                            <p className="feature-desc">{t.features.cards.anime.desc}</p>
                        </div>

                        <div className="feature-card">
                            <div className="feature-icon bg-emerald-500/20">
                                <RefreshCw className="w-7 h-7 text-emerald-400" />
                            </div>
                            <h3 className="feature-title">{t.features.cards.sync.title}</h3>
                            <p className="feature-desc">{t.features.cards.sync.desc}</p>
                        </div>

                        <div className="feature-card">
                            <div className="feature-icon bg-amber-500/20">
                                <Download className="w-7 h-7 text-amber-400" />
                            </div>
                            <h3 className="feature-title">{t.features.cards.download.title}</h3>
                            <p className="feature-desc">{t.features.cards.download.desc}</p>
                        </div>

                        <div className="feature-card">
                            <div className="feature-icon bg-violet-500/20">
                                <Settings className="w-7 h-7 text-violet-400" />
                            </div>
                            <h3 className="feature-title">{t.features.cards.custom.title}</h3>
                            <p className="feature-desc">{t.features.cards.custom.desc}</p>
                        </div>
                    </div>
                </div>
            </section>

            {/* Sources Section */}
            <section id="sources" className="section">
                <div className="container mx-auto px-6">
                    <div className="section-header-center">
                        <div className="section-badge-center">
                            <span className="section-label">{t.sources.sectionTitle}</span>
                        </div>
                        <h2 className="section-title">{t.sources.mainTitle}</h2>
                        <p className="section-subtitle">{t.sources.subtitle}</p>
                    </div>

                    <div className="sources-grid">
                        <div className="source-card">
                            <div className="source-icon">
                                <Mountain className="w-8 h-8 text-indigo-400" />
                            </div>
                            <h3 className="source-name">{t.sources.wallhaven.name}</h3>
                            <p className="source-desc">{t.sources.wallhaven.desc}</p>
                            <div className="source-tags">
                                {t.sources.wallhaven.tags.map((tag, i) => (
                                    <span key={i} className="tag">
                                        {tag}
                                    </span>
                                ))}
                            </div>
                        </div>

                        <div className="source-card featured">
                            <div className="source-badge">HOT</div>
                            <div className="source-icon">
                                <Play className="w-8 h-8 text-cyan-400" />
                            </div>
                            <h3 className="source-name">{t.sources.motionbgs.name}</h3>
                            <p className="source-desc">{t.sources.motionbgs.desc}</p>
                            <div className="source-tags">
                                {t.sources.motionbgs.tags.map((tag, i) => (
                                    <span key={i} className="tag">
                                        {tag}
                                    </span>
                                ))}
                            </div>
                        </div>

                        <div className="source-card">
                            <div className="source-icon">
                                <Tv className="w-8 h-8 text-pink-400" />
                            </div>
                            <h3 className="source-name">{t.sources.anime.name}</h3>
                            <p className="source-desc">{t.sources.anime.desc}</p>
                            <div className="source-tags">
                                {t.sources.anime.tags.map((tag, i) => (
                                    <span key={i} className="tag">
                                        {tag}
                                    </span>
                                ))}
                            </div>
                        </div>
                    </div>
                </div>
            </section>

            {/* CTA Section */}
            <section id="download" className="cta-section">
                <div className="cta-glow" />
                <div className="container mx-auto px-6 relative z-10">
                    <div className="cta-content">
                        <h2 className="cta-title">{t.cta.title}</h2>
                        <p className="cta-subtitle">{t.cta.subtitle}</p>

                        <div className="cta-buttons">
                            <a
                                href="https://github.com/jipika/WaifuX/releases"
                                target="_blank"
                                rel="noopener noreferrer"
                                className="btn-primary btn-large">
                                <Download className="w-6 h-6" />
                                {t.cta.downloadBtn}
                            </a>
                            <a
                                href="https://github.com/jipika/WaifuX"
                                target="_blank"
                                rel="noopener noreferrer"
                                className="btn-secondary btn-large">
                                <GithubIcon className="w-6 h-6" />
                                {t.cta.githubBtn}
                            </a>
                        </div>
                    </div>
                </div>
            </section>

            {/* Footer */}
            <footer className="footer">
                <div className="container mx-auto px-6">
                    <div className="footer-grid">
                        <div className="footer-brand">
                            <div className="footer-logo">
                                <span className="footer-logo-text">WaifuX</span>
                            </div>
                            <p className="footer-desc">
                                {t.footer.description.split("\n").map((line, i) => (
                                    <span key={i}>
                                        {line}
                                        {i < t.footer.description.split("\n").length - 1 && <br />}
                                    </span>
                                ))}
                            </p>
                        </div>

                        <div className="footer-links">
                            <h4 className="footer-heading">{t.footer.links}</h4>
                            <div className="footer-link-list">
                                <a
                                    href="https://github.com/jipika/WaifuX"
                                    target="_blank"
                                    rel="noopener noreferrer"
                                    className="footer-link">
                                    {t.footer.github}
                                </a>
                                <a
                                    href="https://github.com/jipika/WaifuX-Profiles"
                                    target="_blank"
                                    rel="noopener noreferrer"
                                    className="footer-link">
                                    {t.footer.rules}
                                </a>
                            </div>
                        </div>

                        <div className="footer-info">
                            <h4 className="footer-heading">{t.footer.info}</h4>
                            <p className="footer-copyright">
                                {t.footer.copyright.split("\n").map((line, i) => (
                                    <span key={i}>
                                        {line}
                                        {i < t.footer.copyright.split("\n").length - 1 && <br />}
                                    </span>
                                ))}
                            </p>
                        </div>
                    </div>

                    <div className="footer-bottom">
                        <p className="footer-made-with">
                            Made with <Heart className="w-4 h-4 text-red-500 inline" fill="currentColor" /> by jipika
                        </p>
                    </div>
                </div>
            </footer>
        </div>
    )
}

export default App
