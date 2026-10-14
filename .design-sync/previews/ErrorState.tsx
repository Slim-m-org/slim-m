import { ErrorState } from '@slim-m/design-system';

export const WithRetryAndDismiss = () => (
  <ErrorState
    message="Could not load messages. The server is unreachable."
    detail="GET /channels/general/messages - 503"
    onRetry={() => {}}
    onDismiss={() => {}}
  />
);

export const MessageOnly = () => <ErrorState message="Could not rename the channel. You do not have permission." />;

export const RetryOnly = () => (
  <ErrorState message="Could not send the message." onRetry={() => {}} retryLabel="Try again" />
);
