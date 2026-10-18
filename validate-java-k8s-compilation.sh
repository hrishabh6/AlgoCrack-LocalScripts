#!/usr/bin/env bash
# Compile and run a generated Jackson Main.java inside a one-shot Kubernetes Job.
# Uses the same job-runner entrypoint as CXE. Does not replace an existing RC tag.
#
# Usage:
#   scripts/validate-java-k8s-compilation.sh hrishabhjoshi/code-execution-engine:v1.0.0-rc.3
set -euo pipefail

IMAGE="${1:-}"
NAMESPACE="${NAMESPACE:-algocrack}"
JOB_NAME="${JOB_NAME:-cxe-java-classpath-check}"
REDIS_HOST="${REDIS_HOST:-redis}"
REDIS_PORT="${REDIS_PORT:-6379}"
MEMORY_REQUEST="${MEMORY_REQUEST:-512Mi}"
MEMORY_LIMIT="${MEMORY_LIMIT:-1Gi}"

if [[ -z "$IMAGE" ]]; then
  echo "Usage: $0 <code-execution-engine-image>" >&2
  exit 2
fi
if [[ "$IMAGE" == *":v1.0.0-rc.2" || "$IMAGE" == *":latest" ]]; then
  echo "Refusing to validate with an immutable RC2 tag or latest: $IMAGE" >&2
  exit 2
fi

command -v kubectl >/dev/null
command -v python3 >/dev/null

PAYLOAD="$(python3 - << 'PY'
import base64, json
solution = r'''
class Solution {
    public int trapRainWater(int[][] heightMap) {
        if (heightMap == null || heightMap.length == 0 || heightMap[0].length == 0) return 0;
        int m = heightMap.length, n = heightMap[0].length;
        if (m < 3 || n < 3) return 0;
        boolean[][] visited = new boolean[m][n];
        java.util.PriorityQueue<int[]> pq = new java.util.PriorityQueue<>(java.util.Comparator.comparingInt(a -> a[2]));
        for (int i = 0; i < m; i++) for (int j = 0; j < n; j++) {
            if (i == 0 || j == 0 || i == m - 1 || j == n - 1) {
                pq.offer(new int[]{i, j, heightMap[i][j]});
                visited[i][j] = true;
            }
        }
        int result = 0;
        int[][] dirs = {{1,0},{-1,0},{0,1},{0,-1}};
        while (!pq.isEmpty()) {
            int[] cell = pq.poll();
            for (int[] d : dirs) {
                int x = cell[0] + d[0], y = cell[1] + d[1];
                if (x < 0 || y < 0 || x >= m || y >= n || visited[x][y]) continue;
                visited[x][y] = true;
                result += Math.max(0, cell[2] - heightMap[x][y]);
                pq.offer(new int[]{x, y, Math.max(cell[2], heightMap[x][y])});
            }
        }
        return result;
    }
}
'''
body = {
  "submissionId": "classpath-check",
  "executionId": "classpath-check",
  "language": "java",
  "userSolutionCode": solution,
  "questionMetadata": {
    "fullyQualifiedPackageName": "q.trap",
    "functionName": "trapRainWater",
    "returnType": "int",
    "questionType": "ALGORITHM",
    "parameters": [{"name": "heightMap", "type": "int[][]"}]
  },
  "testCases": [{
    "input": {"heightMap": [[1,4,3,1,3,2],[3,2,1,3,2,4],[2,3,3,2,3,1]]}
  }]
}
print(base64.b64encode(json.dumps(body).encode()).decode())
PY
)"

kubectl delete job "$JOB_NAME" -n "$NAMESPACE" --ignore-not-found
kubectl apply -n "$NAMESPACE" -f - << EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
  labels:
    app: code-execution-engine
    component: execution-job
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 300
  activeDeadlineSeconds: 180
  template:
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        fsGroup: 65532
      containers:
        - name: executor
          image: ${IMAGE}
          imagePullPolicy: IfNotPresent
          securityContext:
            runAsNonRoot: true
            runAsUser: 65532
            runAsGroup: 65532
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          env:
            - name: EXECUTION_MODE
              value: job-runner
            - name: EXECUTION_BACKEND
              value: worker-pod
            - name: SPRING_MAIN_WEB_APPLICATION_TYPE
              value: none
            - name: EXECUTION_EXTRA_CLASSPATH
              value: /app/libs/*
            - name: EXECUTION_JOB_PAYLOAD_B64
              value: "${PAYLOAD}"
            - name: SPRING_DATA_REDIS_HOST
              value: "${REDIS_HOST}"
            - name: SPRING_DATA_REDIS_PORT
              value: "${REDIS_PORT}"
          resources:
            requests:
              cpu: 250m
              memory: ${MEMORY_REQUEST}
            limits:
              cpu: "1"
              memory: ${MEMORY_LIMIT}
          volumeMounts:
            - name: tmp
              mountPath: /tmp
            - name: workspace
              mountPath: /workspace
      volumes:
        - name: tmp
          emptyDir: {}
        - name: workspace
          emptyDir: {}
EOF

if ! kubectl wait -n "$NAMESPACE" --for=condition=complete "job/${JOB_NAME}" --timeout=180s; then
  echo "Job did not complete. Pod status and logs:" >&2
  kubectl get pods -n "$NAMESPACE" -l job-name="$JOB_NAME" -o wide >&2 || true
  kubectl logs -n "$NAMESPACE" -l job-name="$JOB_NAME" --tail=200 >&2 || true
  exit 1
fi

logs=""
for _ in 1 2 3 4 5 6; do
  logs="$(kubectl logs -n "$NAMESPACE" "job/${JOB_NAME}" 2>/dev/null || true)"
  if printf '%s\n' "$logs" | grep -F "Compilation successful" >/dev/null \
    && printf '%s\n' "$logs" | grep -F "TEST_CASE_RESULT: 0,4," >/dev/null; then
    echo "Java Kubernetes Job compilation check passed for ${IMAGE}"
    exit 0
  fi
  sleep 2
done
echo "Job completed but expected compilation markers were not in the Job logs." >&2
printf '%s\n' "$logs" | tail -n 80 >&2
exit 1
