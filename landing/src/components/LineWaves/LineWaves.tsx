import { useRef, useMemo } from 'react'
import { Canvas, useFrame } from '@react-three/fiber'

/* ── Nothing-style Line Waves Background ──
   Monochromatic flowing sine waves on OLED-black canvas.
   Enhanced visibility: brighter, thicker, with glow effect.
*/

interface WaveLineProps {
    count: number
    speed: number
    amplitude: number
    frequency: number
    yOffset: number
    opacity: number
}

function WaveLine({ count = 80, speed = 0.8, amplitude = 1.2, frequency = 2.5, yOffset = 0, opacity = 0.6 }: WaveLineProps) {
    const ref = useRef<any>(null)
    
    const positions = useMemo(() => {
        const pos: number[] = []
        const step = 20 / (count - 1)
        for (let i = 0; i < count; i++) {
            const x = -10 + i * step
            pos.push(x, 0, 0)
        }
        return new Float32Array(pos)
    }, [count])

    useFrame((state) => {
        if (!ref.current) return
        const time = state.clock.elapsedTime * speed
        const posArray = ref.current.geometry.attributes.position.array as Float32Array
        const step = 20 / (count - 1)
        
        for (let i = 0; i < count; i++) {
            const x = -10 + i * step
            posArray[i * 3 + 1] = Math.sin(x * frequency + time) * amplitude + yOffset
        }
        ref.current.geometry.attributes.position.needsUpdate = true
    })

    return (
        <line ref={ref}>
            <bufferGeometry>
                <bufferAttribute
                    attach="attributes-position"
                    args={[positions, 3]}
                />
            </bufferGeometry>
            <lineBasicMaterial
                color="#ffffff"
                transparent
                opacity={opacity}
                linewidth={2}
            />
        </line>
    )
}

function LineWavesScene() {
    // Waves tuned for high visibility — much brighter than before
    const waves = [
        // Center wave — brightest and thickest (main visual anchor)
        { amplitude: 2.8, frequency: 1.6, speed: 0.35, yOffset: 0, opacity: 0.35 },
        
        // Upper cluster
        { amplitude: 2.0, frequency: 2.2, speed: 0.5, yOffset: 2.5, opacity: 0.22 },
        { amplitude: 1.4, frequency: 3.0, speed: 0.7, yOffset: 4.0, opacity: 0.14 },
        
        // Lower cluster
        { amplitude: 2.2, frequency: 2.0, speed: 0.45, yOffset: -2.2, opacity: 0.20 },
        { amplitude: 1.6, frequency: 2.8, speed: 0.65, yOffset: -4.0, opacity: 0.12 },

        // Fine detail waves — higher frequency for texture
        { amplitude: 1.8, frequency: 2.5, speed: 0.55, yOffset: 1.0, opacity: 0.16 },
        { amplitude: 1.2, frequency: 3.5, speed: 0.8, yOffset: -1.2, opacity: 0.10 },
    ]

    return (
        <>
            {waves.map((w, i) => (
                <WaveLine
                    key={i}
                    count={120}
                    {...w}
                />
            ))}
        </>
    )
}

interface LineWavesProps {
    className?: string
}

export default function LineWaves({ className }: LineWavesProps) {
    return (
        <div 
            className={`line-waves-container ${className || ''}`}
            style={{ 
                position: 'fixed', 
                top: 0, 
                left: 0, 
                width: '100vw', 
                height: '100vh',
                zIndex: 0,
                pointerEvents: 'none'
            }}
        >
            <Canvas
                dpr={[1, 1.5]}
                camera={{ position: [0, 0, 14], fov: 50 }}
                gl={{ antialias: true, alpha: true }}
                style={{ background: 'transparent' }}
            >
                <LineWavesScene />
            </Canvas>
        </div>
    )
}
