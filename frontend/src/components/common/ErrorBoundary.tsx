import { Component, type ErrorInfo, type ReactNode } from "react";

interface Props {
  children: ReactNode;
  /** Label shown in the error UI, e.g. "Wallet panel" */
  label?: string;
}

interface State {
  error: Error | null;
}

/**
 * ErrorBoundary — prevents a render error in one panel from crashing the whole app.
 * Wrap major tab panels with this so a broken component shows a recovery UI
 * instead of a blank white screen.
 */
export class ErrorBoundary extends Component<Props, State> {
  constructor(props: Props) {
    super(props);
    this.state = { error: null };
  }

  static getDerivedStateFromError(error: Error): State {
    return { error };
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    // eslint-disable-next-line no-console
    console.error(`[ErrorBoundary:${this.props.label ?? "panel"}]`, error, info.componentStack);
  }

  render() {
    if (this.state.error) {
      return (
        <div className="flex flex-col items-center justify-center py-16 px-6 text-center space-y-4">
          <div className="w-10 h-10 rounded-full bg-red-500/20 flex items-center justify-center text-red-400 text-xl">
            ⚠
          </div>
          <div>
            <p className="text-sm font-semibold text-mempool-text mb-1">
              {this.props.label ?? "This panel"} crashed
            </p>
            <p className="text-xs text-mempool-text-dim font-mono break-all max-w-xs">
              {this.state.error.message}
            </p>
          </div>
          <button
            onClick={() => this.setState({ error: null })}
            className="px-4 py-1.5 text-xs bg-mempool-blue/20 hover:bg-mempool-blue/30 text-mempool-blue border border-mempool-blue/30 rounded transition-colors"
          >
            Reload panel
          </button>
        </div>
      );
    }
    return this.props.children;
  }
}
