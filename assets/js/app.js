// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import { Socket } from "phoenix"
import { LiveSocket } from "phoenix_live_view"
// import {hooks as colocatedHooks} from "phoenix-colocated/copy_trade"
import topbar from "../vendor/topbar"

// Hooks for LiveView
let Hooks = {}

Hooks.CumulativeProfitChart = {
  mounted() {
    this.chart = null
    this.handleEvent("chart_data", (data) => {
      this.renderChart(data)
    })
  },

  renderChart(data) {
    const ctx = this.el.querySelector("canvas")
    if (!ctx) return

    // Destroy existing chart
    if (this.chart) {
      this.chart.destroy()
    }

    const labels = data.labels
    const values = data.values
    const profits = data.profits

    // Determine if overall profit is positive
    const lastValue = values.length > 0 ? values[values.length - 1] : 0
    const isPositive = lastValue >= 0

    // Create gradient
    const context2d = ctx.getContext("2d")
    const gradient = context2d.createLinearGradient(0, 0, 0, ctx.height || 300)
    if (isPositive) {
      gradient.addColorStop(0, "rgba(34, 197, 94, 0.3)")
      gradient.addColorStop(1, "rgba(34, 197, 94, 0.01)")
    } else {
      gradient.addColorStop(0, "rgba(239, 68, 68, 0.01)")
      gradient.addColorStop(1, "rgba(239, 68, 68, 0.3)")
    }

    this.chart = new Chart(ctx, {
      type: "line",
      data: {
        labels: labels,
        datasets: [{
          label: "Cumulative Profit ($)",
          data: values,
          borderColor: isPositive ? "rgb(34, 197, 94)" : "rgb(239, 68, 68)",
          backgroundColor: gradient,
          borderWidth: 2.5,
          fill: true,
          tension: 0.3,
          pointRadius: values.length > 30 ? 0 : 4,
          pointHoverRadius: 6,
          pointBackgroundColor: isPositive ? "rgb(34, 197, 94)" : "rgb(239, 68, 68)",
          pointBorderColor: "#fff",
          pointBorderWidth: 2,
        }]
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        interaction: {
          intersect: false,
          mode: "index",
        },
        plugins: {
          legend: { display: false },
          tooltip: {
            backgroundColor: "rgba(15, 23, 42, 0.9)",
            titleFont: { size: 12, weight: "600" },
            bodyFont: { size: 13, weight: "bold" },
            padding: 12,
            cornerRadius: 8,
            displayColors: false,
            callbacks: {
              label: function (context) {
                const val = context.parsed.y
                const sign = val >= 0 ? "+" : ""
                const tradeProfit = profits[context.dataIndex]
                const tradeProfitSign = tradeProfit >= 0 ? "+" : ""
                return [
                  `สะสม: ${sign}$${val.toFixed(2)}`,
                  `Trade: ${tradeProfitSign}$${tradeProfit.toFixed(2)}`
                ]
              }
            }
          }
        },
        scales: {
          x: {
            grid: { display: false },
            ticks: {
              maxTicksLimit: 8,
              font: { size: 10 },
              color: "#9ca3af",
            },
            border: { display: false },
          },
          y: {
            grid: {
              color: "rgba(156, 163, 175, 0.15)",
              drawBorder: false,
            },
            ticks: {
              font: { size: 11 },
              color: "#9ca3af",
              callback: function (value) { return "$" + value.toFixed(0) }
            },
            border: { display: false },
          }
        }
      }
    })
  },

  destroyed() {
    if (this.chart) {
      this.chart.destroy()
    }
  }
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: { _csrf_token: csrfToken },
  hooks: Hooks,
})

// Show progress bar on live navigation and form submits
topbar.config({ barColors: { 0: "#29d" }, shadowColor: "rgba(0, 0, 0, .3)" })
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({ detail: reloader }) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if (keyDown === "c") {
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if (keyDown === "d") {
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

window.addEventListener("phx:play_alert_sound", (e) => {
  const audio = new Audio("/sounds/emergency_alert.mp3");
  audio.play();
});
