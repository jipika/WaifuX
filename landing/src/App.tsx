import { useState, useEffect } from 'react';
import LineWaves from "./components/LineWaves/LineWaves"
import ScrollReveal from "./components/ScrollReveal/ScrollReveal"
import { Download, Search, Sparkles, Film, RefreshCw, Settings, Play, Tv, Heart, Star, ArrowRight, ExternalLink, ChevronRight, Command, Zap, Layers } from "lucide-react"
import { useLanguage } from "./contexts/LanguageContext"
import { LanguageSwitcher } from "./components/LanguageSwitcher"
import "./App.css"

/* ── Nothing Design System: WaifuX Landing ──
    Monochrome · Typographic · Industrial
*/

const GithubIcon = ({ className }: { className?: string }) => (
    <svg className={className} viewBox="0 0 24 24" fill="currentColor">
        <path d="M12 0c-6.626 0-12 5.373-12 12 0 5.302 3.438 9.8 8.207 11.387.599.111.793-.261.793-.577v-2.234c-3.338.726-4.033-1.416-4.033-1.416-.546-1.387-1.333-1.756-1.333-1.756-1.089-.745.083-.729.083-.729 1.205.084 1.839 1.237 1.839 1.237 1.07 1.834 2.807 1.304 3.492.997.107-.775.418-1.305.762-1.604-2.665-.305-5.467-1.334-5.467-5.931 0-1.311.469-2.381 1.236-3.221-.124-.303-.535-1.524.117-3.176 0 0 1.008-.322 3.301 1.23.957-.266 1.983-.399 3.003-.404 1.02.005 2.047.138 3.006.404 2.291-1.552 3.297-1.23 3.297-1.23.653 1.653.242 2.874.118 3.176.77.84 1.235 1.911 1.235 3.221 0 4.609-2.807 5.624-5.479 5.921.43.372.823 1.102.823 2.222v3.293c0 .319.192.694.801.576 4.765-1.589 8.199-6.086 8.199-11.386 0-6.627-5.373-12-12-12z" />
    </svg>
)

/* ── Stats Bar ── */
function StatsBar() {
    const { t } = useLanguage()
    const stats = t.stats.items
    
    return (
        <div className="nt-stats">
            {stats.map((stat: { number: string; label: string }, i: number) => (
                <div key={i} className="nt-stat-item">
                    <span className="nt-stat-number">{stat.number}</span>
                    <span className="nt-stat-label">{stat.label}</span>
                </div>
            ))}
        </div>
    )
}

/* ── Feature Cards (Nothing-style monochrome) ── */
function FeatureGrid() {
    const { t } = useLanguage()
    const cards = t.bentoCards
    
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const cardList: any[] = [
        { title: cards.search.title, desc: cards.search.desc, iconBg: cards.search.iconBg, icon: Search },
        { title: cards.dynamic.title, desc: cards.dynamic.desc, iconBg: cards.dynamic.iconBg, icon: Film },
        { title: cards.anime.title, desc: cards.anime.desc, iconBg: cards.anime.iconBg, icon: Sparkles },
        { title: cards.sync.title, desc: cards.sync.desc, iconBg: cards.sync.iconBg, icon: RefreshCw },
        { title: cards.download.title, desc: cards.download.desc, iconBg: cards.download.iconBg, icon: Download },
        { title: cards.custom.title, desc: cards.custom.desc, iconBg: cards.custom.iconBg, icon: Settings, tags: cards.custom.tags },
    ]

    return (
        <div className="nt-feature-grid">
            {cardList.map((card, i) => (
                <ScrollReveal key={i} delay={i * 80} direction="up">
                    <div className={`nt-feature-card ${i === 0 ? 'nt-fc-hero' : ''} ${[2,3].includes(i) ? 'nt-fc-highlight' : ''}`}>
                        <div className={`nt-fc-icon`}>
                            <card.icon className="w-5 h-5" strokeWidth={1.5} />
                        </div>
                        <h3>{card.title}</h3>
                        <p>{card.desc}</p>
                        {card.tags && (
                            <div className="nt-fc-tags">
                                {card.tags.map((tag: string, j: number) => (
                                    <span key={j} className="nt-tag">{tag}</span>
                                ))}
                            </div>
                        )}
                    </div>
                </ScrollReveal>
            ))}
        </div>
    )
}

/* ── Source Cards (Nothing industrial style) ── */
function SourceSection() {
    const { t } = useLanguage()

    return (
        <div className="nt-sources">
            <ScrollReveal>
                <div className="nt-source-card nt-source-main">
                    <div className="nt-source-header">
                        <Play className="w-8 h-8" strokeWidth={1.5} />
                        <span className="nt-source-badge">POPULAR</span>
                    </div>
                    <h3>{t.sources.motionbgs.name}</h3>
                    <p>{t.sources.motionbgs.desc}</p>
                    <div className="nt-source-tags">
                        {t.sources.motionbgs.tags.map((tag: string, i: number) => (
                            <span key={i} className="nt-tag">{tag}</span>
                        ))}
                    </div>
                </div>
            </ScrollReveal>

            <div className="nt-source-row">
                <ScrollReveal delay={120}>
                    <div className="nt-source-card nt-source-mini">
                        <Layers className="w-6 h-6 mb-4" strokeWidth={1.5} />
                        <h3>{t.sources.wallhaven.name}</h3>
                        <p>{t.sources.wallhaven.desc}</p>
                        <div className="nt-tags-sm">
                            {t.sources.wallhaven.tags.map((tag: string, i: number) => (
                                <span key={i} className="nt-tag-sm">{tag}</span>
                            ))}
                        </div>
                    </div>
                </ScrollReveal>

                <ScrollReveal delay={200}>
                    <div className="nt-source-card nt-source-mini">
                        <Tv className="w-6 h-6 mb-4" strokeWidth={1.5} />
                        <h3>{t.sources.anime.name}</h3>
                        <p>{t.sources.anime.desc}</p>
                        <div className="nt-tags-sm">
                            {t.sources.anime.tags.map((tag: string, i: number) => (
                                <span key={i} className="nt-tag-sm">{tag}</span>
                            ))}
                        </div>
                    </div>
                </ScrollReveal>
            </div>
        </div>
    )
}

/* ── Main App ── */
function App() {
    const { t } = useLanguage()
    const [scrolled, setScrolled] = useState(false)

    useEffect(() => {
        let ticking = false
        const handleScroll = () => {
            if (!ticking) {
                requestAnimationFrame(() => {
                    setScrolled(window.scrollY > 40)
                    ticking = false
                })
                ticking = true
            }
        }
        window.addEventListener('scroll', handleScroll, { passive: true })
        return () => window.removeEventListener('scroll', handleScroll)
    }, [])

    return (
        <div className="nt-app">
            {/* Line Waves Background */}
            <LineWaves />

            {/* Subtle dot grid overlay */}
            <div className="nt-dot-grid" aria-hidden="true" />

            {/* ═══ NAVBAR ═══ */}
            <nav className={`nt-nav ${scrolled ? 'nt-nav-scrolled' : ''}`}>
                <div className="nt-nav-inner">
                    <a href="#" className="nt-brand">
                        <Command className="w-4 h-4" strokeWidth={2} />
                        <span>WaifuX</span>
                    </a>

                    <div className="nt-nav-links">
                        <a href="#features" className="nt-nav-link">{t.nav.features}</a>
                        <a href="#sources" className="nt-nav-link">{t.nav.sources}</a>
                        <a href="#download" className="nt-nav-link">{t.nav.download}</a>
                    </div>

                    <div className="nt-nav-actions">
                        <LanguageSwitcher />
                        <a 
                            href="https://github.com/jipika/WaifuX" 
                            target="_blank" 
                            rel="noopener noreferrer" 
                            className="nt-btn-icon"
                            aria-label="GitHub"
                        >
                            <GithubIcon className="w-4 h-4" />
                        </a>
                        <a
                            href="https://github.com/jipika/WaifuX/releases/latest"
                            target="_blank"
                            rel="noopener noreferrer"
                            className="nt-btn-primary"
                        >
                            <Download className="w-3.5 h-3.5" />
                            <span>{t.hero.downloadBtn}</span>
                        </a>
                    </div>
                </div>
            </nav>

            {/* ═══ HERO SECTION ═══ */}
            <section className="nt-hero">
                <div className="nt-container">
                    <div className="nt-hero-inner">
                        {/* Badge — static text, no animation */}
                        <div className="nt-badge">
                            <Zap className="w-3 h-3" />
                            <span>{t.hero.badge}</span>
                            <ChevronRight className="w-3 h-3 opacity-50" />
                        </div>

                        {/* Static Big Title */}
                        <h1 className="nt-hero-title">
                            {t.hero.titleLine1}
                            <br />
                            <span className="nt-title-accent">{t.hero.titleLine2}</span>
                        </h1>

                        {/* Description — concise */}
                        <p className="nt-hero-desc">{t.hero.description}</p>

                        {/* CTA Buttons */}
                        <div className="nt-hero-actions">
                            <a
                                href="https://github.com/jipika/WaifuX/releases/latest"
                                target="_blank"
                                rel="noopener noreferrer"
                                className="nt-btn-hero"
                            >
                                <Download className="w-[18px] h-[18px]" />
                                <span>{t.hero.downloadBtn}</span>
                                <ArrowRight className="w-4 h-4 ml-auto opacity-60 group-hover:translate-x-0.5 transition-transform" />
                            </a>
                            <a
                                href="https://github.com/jipika/WaifuX"
                                target="_blank"
                                rel="noopener noreferrer"
                                className="nt-btn-ghost"
                            >
                                <GithubIcon className="w-[18px] h-[18px]" />
                                <span>{t.hero.sourceBtn}</span>
                                <ExternalLink className="w-3 h-3 opacity-40" />
                            </a>
                        </div>

                        {/* Stats */}
                        <StatsBar />

                        {/* Device Preview Frame */}
                        <div className="nt-device-frame">
                            <div className="nt-device-header">
                                <div className="nt-device-dots">
                                    <span className="nt-dot nt-dot-red" />
                                    <span className="nt-dot nt-dot-yellow" />
                                    <span className="nt-dot nt-dot-green" />
                                </div>
                                <span className="nt-device-title">WaifuX</span>
                                <div className="nt-device-controls">
                                    <span className="nt-control-line" />
                                </div>
                            </div>
                            <div className="nt-device-body">
                                <div className="nt-dev-sidebar">
                                    {[...Array(5)].map((_, i) => (
                                        <div key={i} className={`nt-dev-side-item ${i === 0 ? 'active' : ''} ${i === 3 ? 'short' : ''}`} />
                                    ))}
                                </div>
                                <div className="nt-dev-main">
                                    <div className="nt-dev-search" />
                                    <div className="nt-dev-grid">
                                        {['#6366f1','#06b6d4','#ec4899','#8b5cf6','#f59e0b','#10b981'].map((color, i) => (
                                            <div 
                                                key={i} 
                                                className="nt-dev-card" 
                                                style={{ background: `linear-gradient(135deg, ${color}25, ${color}10)` }}
                                            />
                                        ))}
                                    </div>
                                </div>
                            </div>
                        </div>
                    </div>
                </div>
            </section>

            {/* ═══ FEATURES SECTION ═══ */}
            <section id="features" className="nt-section">
                <div className="nt-container">
                    <ScrollReveal>
                        <div className="nt-section-head">
                            <div className="nt-section-label">
                                <span className="nt-label-dot" />
                                <span>{t.features.sectionTitle}</span>
                            </div>
                            <h2 className="nt-section-title">
                                {t.features.mainTitle.split('\n').map((line: string, i: number) => (
                                    <span key={i}>
                                        {i > 0 && <br />}{line}
                                    </span>
                                ))}
                            </h2>
                            <p className="nt-section-desc">{t.features.subtitle}</p>
                        </div>
                    </ScrollReveal>

                    <FeatureGrid />
                </div>
            </section>

            {/* ═══ SOURCES SECTION ═══ */}
            <section id="sources" className="nt-section nt-section-alt">
                <div className="nt-container">
                    <ScrollReveal>
                        <div className="nt-section-head center">
                            <div className="nt-section-label">
                                <Layers className="w-3.5 h-3.5" />
                                <span>{t.sources.sectionTitle}</span>
                            </div>
                            <h2 className="nt-section-title">{t.sources.mainTitle}</h2>
                            <p className="nt-section-desc">{t.sources.subtitle}</p>
                        </div>
                    </ScrollReveal>

                    <SourceSection />
                </div>
            </section>

            {/* ═══ CTA SECTION ═══ */}
            <section id="download" className="nt-cta">
                <div className="nt-cta-glow" />
                <div className="nt-container">
                    <ScrollReveal>
                        <div className="nt-cta-inner">
                            <div className="nt-cta-icon">
                                <Download className="w-7 h-7" strokeWidth={1.5} />
                            </div>
                            <h2 className="nt-cta-title">{t.cta.title}</h2>
                            <p className="nt-cta-desc">{t.cta.subtitle}</p>
                            
                            <div className="nt-cta-actions">
                                <a
                                    href="https://github.com/jipika/WaifuX/releases/latest"
                                    target="_blank"
                                    rel="noopener noreferrer"
                                    className="nt-btn-hero large"
                                >
                                    <Download className="w-5 h-5" />
                                    <span>{t.cta.downloadBtn}</span>
                                    <ArrowRight className="w-4 h-4" />
                                </a>
                                <a
                                    href="https://github.com/jipika/WaifuX"
                                    target="_blank"
                                    rel="noopener noreferrer"
                                    className="nt-btn-ghost large"
                                >
                                    <Star className="w-5 h-5" />
                                    <span>{t.cta.githubBtn}</span>
                                </a>
                            </div>

                            <p className="nt-cta-meta">{t.cta.note}</p>
                        </div>
                    </ScrollReveal>
                </div>
            </section>

            {/* ═══ FOOTER ═══ */}
            <footer className="nt-footer">
                <div className="nt-footer-border" aria-hidden="true" />
                <div className="nt-container">
                    <div className="nt-footer-top">
                        <div className="nt-footer-brand">
                            <div className="nt-footer-logo">
                                <Command className="w-5 h-5" strokeWidth={2} />
                                <span>WaifuX</span>
                            </div>
                            <p className="nt-footer-about">{t.footer.description.split('\n')[0]}</p>
                        </div>
                        
                        <div className="nt-footer-links">
                            <div className="nt-footer-col">
                                <h4>{t.footer.links}</h4>
                                <a href="https://github.com/jipika/WaifuX" target="_blank" rel="noopener noreferrer">
                                    <GithubIcon className="w-3.5 h-3.5" />{t.footer.github}
                                </a>
                                <a href="https://github.com/jipika/WaifuX-Profiles" target="_blank" rel="noopener noreferrer">
                                    <ExternalLink className="w-3 h-3" />{t.footer.rules}
                                </a>
                            </div>
                            <div className="nt-footer-col">
                                <h4>{t.footer.info}</h4>
                                <p className="nt-footer-copy">{t.footer.copyright.split('\n')[0]}</p>
                                <p className="nt-footer-license">MIT License</p>
                            </div>
                        </div>
                    </div>
                    
                    <div className="nt-footer-bottom">
                        <p>
                            Made with <Heart className="w-3 h-3 inline mx-0.5 align-middle" fill="currentColor" /> by jipika
                        </p>
                    </div>
                </div>
            </footer>
        </div>
    )
}

export default App
