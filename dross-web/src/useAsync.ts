import { useEffect, useState } from 'react'
import { ApiError } from './api'

export type Async<T> =
  | { state: 'loading' }
  | { state: 'ready'; value: T }
  | { state: 'failed'; error: ApiError }

/** Run a request, cancelling it if the inputs change or the view unmounts. */
export function useAsync<T>(
  run: (signal: AbortSignal) => Promise<T>,
  deps: unknown[],
): Async<T> {
  const [result, setResult] = useState<Async<T>>({ state: 'loading' })

  useEffect(() => {
    const controller = new AbortController()
    setResult({ state: 'loading' })
    run(controller.signal)
      .then((value) => setResult({ state: 'ready', value }))
      .catch((error: unknown) => {
        if (controller.signal.aborted) return
        setResult({
          state: 'failed',
          error:
            error instanceof ApiError
              ? error
              : new ApiError('Something went wrong loading this.', 0),
        })
      })
    return () => controller.abort()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps)

  return result
}
