import { useState, useEffect, useCallback } from 'react'

/* ── Nothing-style Shuffle Text Animation ──
   Characters cycle through a random set before settling
   on the final text. Mechanical, industrial feel.
*/

const CHARS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#$%&*'

interface ShuffleTextProps {
    text: string
    className?: string
    as?: 'h1' | 'h2' | 'h3' | 'span' | 'p'
    delay?: number
    scrambleDuration?: number // total ms for the scramble effect
}

function useScramble(finalText: string, isActive: boolean, duration: number = 2000) {
    const [displayText, setDisplayText] = useState(finalText)

    const scramble = useCallback(() => {
        if (!isActive) return
        
        const chars = finalText.split('')
        const startTime = Date.now()
        
        const tick = () => {
            const elapsed = Date.now() - startTime
            const progress = Math.min(elapsed / duration, 1)
            
            // Easing: fast start, slow end (ease-out cubic)
            const eased = 1 - Math.pow(1 - progress, 3)
            
            // Each character has its own reveal timing based on index
            setDisplayText(
                chars.map((char, i) => {
                    const charProgress = Math.max(0, eased - (i * 0.06))
                    if (charProgress >= 1 || char === ' ' || char === '\n') return char
                    if (charProgress <= 0) return CHARS[Math.floor(Math.random() * CHARS.length)]
                    
                    // Transition probability increases with progress
                    const revealProb = charProgress * charProgress
                    return Math.random() < revealProb ? char : CHARS[Math.floor(Math.random() * CHARS.length)]
                }).join('')
            )
            
            if (progress < 1) {
                requestAnimationFrame(tick)
            } else {
                setDisplayText(finalText)
            }
        }
        
        requestAnimationFrame(tick)
    }, [finalText, duration, isActive])

    useEffect(() => {
        if (isActive) {
            const timeout = setTimeout(scramble, 100)
            return () => clearTimeout(timeout)
        }
    }, [isActive, scramble])

    return displayText
}

export default function ShuffleText({ 
    text, 
    className = '', 
    as: Tag = 'h1', 
    delay = 0,
    scrambleDuration = 1800 
}: ShuffleTextProps) {
    const [isVisible, setIsVisible] = useState(false)
    
    useEffect(() => {
        const timer = setTimeout(() => setIsVisible(true), delay)
        return () => clearTimeout(timer)
    }, [delay])

    const displayText = useScramble(text, isVisible, scrambleDuration)

    return (
        <Tag className={className} style={{ minHeight: '1em' }}>
            {displayText}
        </Tag>
    )
}

/* ── Multi-line Shuffle Title ── */
interface ShuffleTitleProps {
    lines: string[]
    className?: string
    highlightLine?: number // which line to apply accent styling (0-indexed)
}

export function ShuffleTitle({ lines, className = '', highlightLine }: ShuffleTitleProps) {
    const [isVisible, setIsVisible] = useState(false)
    
    useEffect(() => {
        const timer = setTimeout(() => setIsVisible(true), 300)
        return () => clearTimeout(timer)
    }, [])

    return (
        <div className={`shuffle-title-group ${className}`}>
            {lines.map((line, i) => {
                const displayText = useScramble(line, isVisible, 1600 + i * 300)
                return (
                    <span 
                        key={i} 
                        className={`shuffle-title-line ${i === highlightLine ? 'accent-line' : ''}`}
                        style={{ animationDelay: `${i * 120}ms` }}
                    >
                        {displayText}
                        {line.includes('\n') ? null : (i < lines.length - 1 && !line.includes('\n'))}
                    </span>
                )
            })}
        </div>
    )
}

export { ShuffleText }
