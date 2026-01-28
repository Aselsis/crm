import { createResource } from 'frappe-ui'

declare global {
  interface Window {
    posthog: any
  }
}
type PosthogSettings = {
  posthog_project_id: string
  posthog_host: string
  enable_telemetry: boolean
  telemetry_site_age: number
}
interface CaptureOptions {
  data: {
    user: string
    [key: string]: string | number | boolean | object
  }
}

let posthog: typeof window.posthog = window.posthog
let posthogLoadPromise: Promise<void> | null = null

function ensurePosthogLoaded() {
  if (typeof window === 'undefined') return Promise.resolve()
  if (window.posthog?.init) return Promise.resolve()

  if (posthogLoadPromise) return posthogLoadPromise

  posthogLoadPromise = new Promise<void>((resolve) => {
    const existing = document.querySelector(
      'script[data-crm-posthog-loader="1"]',
    ) as HTMLScriptElement | null

    if (existing) {
      existing.addEventListener('load', () => resolve(), { once: true })
      existing.addEventListener('error', () => resolve(), { once: true })
      return
    }

    const script = document.createElement('script')
    script.dataset.crmPosthogLoader = '1'
    script.async = true
    script.src = '/assets/frappe/js/lib/posthog.js'
    script.addEventListener('load', () => resolve(), { once: true })
    script.addEventListener('error', () => resolve(), { once: true })
    document.head.appendChild(script)
  })

  return posthogLoadPromise
}

// Posthog Settings
let posthogSettings = createResource({
  url: 'crm.api.get_posthog_settings',
  cache: 'posthog_settings',
  onSuccess: (ps: PosthogSettings) => initPosthog(ps),
})

let isTelemetryEnabled = () => {
  if (!posthogSettings.data) return false

  return (
    posthogSettings.data.enable_telemetry &&
    posthogSettings.data.posthog_project_id &&
    posthogSettings.data.posthog_host
  )
}

// Posthog Initialization
function initPosthog(ps: PosthogSettings) {
  if (!isTelemetryEnabled()) return

  ensurePosthogLoaded().then(() => {
    posthog = window.posthog
    if (!posthog?.init) return

    posthog.init(ps.posthog_project_id, {
      api_host: ps.posthog_host,
      person_profiles: 'identified_only',
      autocapture: false,
      capture_pageview: true,
      capture_pageleave: true,
      enable_heatmaps: false,
      disable_session_recording: true,
      advanced_disable_decide: true,
      loaded: (ph: typeof posthog) => {
        window.posthog = ph
        ph.identify(window.location.hostname)
      },
    })
  })
}

// Posthog Functions
function capture(
  event: string,
  options: CaptureOptions = { data: { user: '' } },
) {
  if (!isTelemetryEnabled()) return
  window.posthog.capture(`crm_${event}`, options)
}

function startRecording() {
}

function stopRecording() {
}

// Posthog Plugin
function posthogPlugin(app: any) {
  app.config.globalProperties.posthog = posthog
  if (!window.posthog?.length) posthogSettings.fetch()
}

export {
  posthog,
  posthogSettings,
  posthogPlugin,
  capture,
  startRecording,
  stopRecording,
}
