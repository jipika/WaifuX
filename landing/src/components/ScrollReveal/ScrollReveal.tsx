import { useEffect, useRef, useState } from 'react'

/* ── Nothing-style Scroll Reveal ──
   Mechanical slide-up reveal on scroll into viewport.
   Uses IntersectionObserver with stagger support.
*/

interface ScrollRevealProps {
    children: React.ReactNode
    className?: string
    delay?: number // ms delay before animation starts (for stagger)
    direction?: 'up' | 'left' | 'right'
    duration?: number
    once?: boolean
}

export default function ScrollReveal({
    children,
    className = '',
    delay = 0,
    direction = 'up',
    duration = 700,
    once = true
}: ScrollRevealProps) {
    const ref = useRef<HTMLDivElement>(null)
    const [isVisible, setIsVisible] = useState(false)

    useEffect(() => {
        const el = ref.current
        if (!el) return

        const observer = new IntersectionObserver(
            ([entry]) => {
                if (entry.isIntersecting) {
                    // Small delay for natural feel
                    const timer = setTimeout(() => setIsVisible(true), delay + 50)
                    if (once) observer.unobserve(el)
                    return () => clearTimeout(timer)
                } else if (!once) {
                    setIsVisible(false)
                }
            },
            { threshold: 0.15, rootMargin: '0px 0px -40px 0px' }
        )

        observer.observe(el)
        return () => observer.disconnect()
    }, [delay, once])

    return (
        <div
            ref={ref}
            className={`scroll-reveal ${className} ${isVisible ? 'is-visible' : ''}`}
            style={{
                '--reveal-delay': `${delay}ms`,
                '--reveal-duration': `${duration}ms`,
                '--reveal-dir-x': direction === 'left' ? '-1' : direction === 'right' ? '1' : '0',
                '--reveal-dir-y': direction === 'up' ? '1' : '0',
            } as React.CSSProperties}
        >
            {children}
        </div>
    )
}

/* ── Staggered Children Wrapper ── */
interface StaggerGroupProps {
    children: React.ReactNode[]
    className?: string
    staggerDelay?: number // ms between each child
    direction?: 'up' | 'left' | 'right'
}

export function StaggerReveal({ 
    children, 
    className = '', 
    staggerDelay = 100,
    direction = 'up' 
}: StaggerGroupProps) {
    return (
        <div className={`stagger-group ${className}`}>
            {children.map((child, i) => (
                <ScrollReveal 
                    key={i} 
                    delay={i * staggerDelay} 
                    direction={direction}
                >
                    {child}
                </ScrollReveal>
            ))}
        </div>
    )
}
