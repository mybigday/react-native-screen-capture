/**
 * Demo for @fugood/react-native-screen-capture.
 *
 * The video below is the point of the whole exercise: it renders into a SurfaceView on
 * Android and an AVPlayerLayer / AVPlayerViewController on iOS, neither of which a normal
 * screenshot can see. Capture the screen and it should appear in the result, not as a
 * black rectangle.
 */

import React, { useCallback, useEffect, useRef, useState } from 'react'
import {
  Image,
  Platform,
  Pressable,
  SafeAreaView,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native'
import Video from 'react-native-video'
import ScreenCapture, {
  type CaptureMode,
  type CaptureOptions,
  type CaptureResult,
  type PermissionStatus,
  type Subscription,
} from '@fugood/react-native-screen-capture'

const SAMPLE_VIDEO =
  'https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/360/Big_Buck_Bunny_360_10s_1MB.mp4'

const MODES: CaptureMode[] = ['auto', 'view', 'accessibility']

export default function App() {
  const [mode, setMode] = useState<CaptureMode>('auto')
  const [result, setResult] = useState<CaptureResult | null>(null)
  const [status, setStatus] = useState<string>('Ready')
  const [accessibility, setAccessibility] = useState<PermissionStatus>('unavailable')
  const [screenshots, setScreenshots] = useState(0)
  const [dump, setDump] = useState<string | null>(null)
  const [detecting, setDetecting] = useState(false)
  const subscription = useRef<Subscription | null>(null)

  const refreshAccessibility = useCallback(async () => {
    setAccessibility(await ScreenCapture.getPermissionStatus('accessibility'))
  }, [])

  useEffect(() => {
    refreshAccessibility()
  }, [refreshAccessibility])

  useEffect(() => () => subscription.current?.remove(), [])

  const run = useCallback(
    async (label: string, action: () => Promise<void>) => {
      setStatus(`${label}...`)
      const started = Date.now()
      try {
        await action()
        setStatus(`${label} took ${Date.now() - started}ms`)
      } catch (error: any) {
        setStatus(`${label} failed: ${error?.message ?? error}`)
      }
    },
    [],
  )

  const capture = useCallback(
    (label: string, options: CaptureOptions) =>
      run(label, async () => {
        setDump(null)
        setResult(await ScreenCapture.capture({ mode, ...options }))
      }),
    [mode, run],
  )

  const toggleDetection = useCallback(() => {
    if (subscription.current) {
      subscription.current.remove()
      subscription.current = null
      setDetecting(false)
      setStatus('Screenshot detection off')
      return
    }
    subscription.current = ScreenCapture.addScreenshotListener(() => {
      setScreenshots((count) => count + 1)
    })
    setDetecting(true)
    setStatus('Screenshot detection on — now take a screenshot yourself')
  }, [])

  return (
    <SafeAreaView style={styles.root}>
      <ScrollView contentContainerStyle={styles.content}>
        <Text style={styles.title}>Screen Capture</Text>
        <Text style={styles.status}>{status}</Text>

        <Section title="Live video (SurfaceView / AVPlayerLayer)">
          <Video
            source={{ uri: SAMPLE_VIDEO }}
            style={styles.video}
            resizeMode="contain"
            repeat
            muted
            // Force a SurfaceView on Android: that is the case a plain window readback
            // cannot see, and the one this library composites back in.
            useTextureView={false}
          />
        </Section>

        <Section title="Capture mode">
          <View style={styles.row}>
            {MODES.map((candidate) => (
              <Button
                key={candidate}
                label={candidate}
                active={mode === candidate}
                onPress={() => setMode(candidate)}
              />
            ))}
          </View>
          {Platform.OS === 'android' && (
            <View style={styles.row}>
              <Text style={styles.note}>accessibility: {accessibility}</Text>
              {accessibility !== 'granted' && (
                <Button
                  label="Enable"
                  onPress={async () => {
                    await ScreenCapture.openAccessibilitySettings()
                    setStatus('Enable the service, then come back and press Refresh')
                  }}
                />
              )}
              <Button label="Refresh" onPress={refreshAccessibility} />
            </View>
          )}
        </Section>

        <Section title="Capture">
          <View style={styles.row}>
            <Button label="PNG" onPress={() => capture('Capture PNG', {})} />
            <Button
              label="JPEG @0.5"
              onPress={() =>
                capture('Capture JPEG', { extension: 'jpg', quality: 80, scale: 0.5 })
              }
            />
            <Button
              label="No status bar"
              onPress={() => capture('Capture cropped', { excludeStatusBar: true })}
            />
          </View>
          <View style={styles.row}>
            <Button label="Warm up" onPress={() => run('Warm up', ScreenCapture.warmUp)} />
            <Button label="Cool down" onPress={() => run('Cool down', ScreenCapture.coolDown)} />
            <Button
              label="Clear cache"
              onPress={() =>
                run('Clear cache', async () => {
                  const removed = await ScreenCapture.clearCache()
                  setResult(null)
                  setStatus(`Removed ${removed} files`)
                })
              }
            />
          </View>
        </Section>

        <Section title="Screenshot detection">
          <View style={styles.row}>
            <Button
              label={detecting ? 'Stop' : 'Start'}
              onPress={toggleDetection}
            />
            <Text style={styles.note}>detected: {screenshots}</Text>
          </View>
        </Section>

        <Section title="Diagnostics">
          <Button
            label="Dump hierarchy"
            onPress={() =>
              run('Dump', async () => {
                setResult(null)
                setDump(await ScreenCapture.dumpHierarchy())
              })
            }
          />
        </Section>

        {result && (
          <Section title="Result">
            <Text style={styles.note}>
              {result.width} x {result.height}
            </Text>
            <Image source={{ uri: result.uri }} style={styles.preview} resizeMode="contain" />
            <Text style={styles.path} numberOfLines={2}>
              {result.uri}
            </Text>
          </Section>
        )}

        {dump && (
          <Section title="Hierarchy">
            <ScrollView horizontal>
              <Text style={styles.dump}>{dump}</Text>
            </ScrollView>
          </Section>
        )}
      </ScrollView>
    </SafeAreaView>
  )
}

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <View style={styles.section}>
      <Text style={styles.sectionTitle}>{title}</Text>
      {children}
    </View>
  )
}

function Button({
  label,
  onPress,
  active,
}: {
  label: string
  onPress: () => void
  active?: boolean
}) {
  return (
    <Pressable
      onPress={onPress}
      style={({ pressed }) => [
        styles.button,
        active && styles.buttonActive,
        pressed && styles.buttonPressed,
      ]}>
      <Text style={[styles.buttonLabel, active && styles.buttonLabelActive]}>{label}</Text>
    </Pressable>
  )
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: '#0f1115' },
  content: { padding: 16, paddingBottom: 48 },
  title: { color: '#f5f7fa', fontSize: 26, fontWeight: '700' },
  status: { color: '#8b93a7', marginTop: 4, marginBottom: 12 },
  section: { marginBottom: 20 },
  sectionTitle: {
    color: '#8b93a7',
    fontSize: 12,
    fontWeight: '600',
    textTransform: 'uppercase',
    letterSpacing: 0.8,
    marginBottom: 8,
  },
  row: { flexDirection: 'row', flexWrap: 'wrap', alignItems: 'center', gap: 8 },
  video: { width: '100%', aspectRatio: 16 / 9, backgroundColor: '#000', borderRadius: 8 },
  button: {
    paddingHorizontal: 14,
    paddingVertical: 9,
    borderRadius: 8,
    backgroundColor: '#1c2029',
    borderWidth: 1,
    borderColor: '#2a3040',
  },
  buttonActive: { backgroundColor: '#2f6df6', borderColor: '#2f6df6' },
  buttonPressed: { opacity: 0.6 },
  buttonLabel: { color: '#c8cfdd', fontSize: 14 },
  buttonLabelActive: { color: '#fff', fontWeight: '600' },
  note: { color: '#8b93a7', fontSize: 13 },
  preview: {
    width: '100%',
    height: 320,
    backgroundColor: '#1c2029',
    borderRadius: 8,
    marginTop: 8,
  },
  path: { color: '#5d6577', fontSize: 11, marginTop: 6 },
  dump: { color: '#9fb2d1', fontFamily: Platform.OS === 'ios' ? 'Menlo' : 'monospace', fontSize: 10 },
})
