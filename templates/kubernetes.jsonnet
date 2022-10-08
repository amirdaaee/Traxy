local context = import '../context.jsonnet';
local enums = {
  apiVersion: 'v1',
  ConfigMap: 'ConfigMap',
  Secret: 'Secret',
  Deployment: 'Deployment',
  Service: 'Service',
};
local
  cm_env = {
    apiVersion: enums.apiVersion,
    kind: enums.ConfigMap,
    metadata: {
      name: context.name + '-env',
    },
    data: {
      REMOTE_ADDRESS: context.remote_address,
      REMOTE_SNI: context.remote_sni,
      TRAEFIK_ENTRYPOINTS_RELAY: 'true',
      TRAEFIK_ENTRYPOINTS_RELAY_ADDRESS: ':' + context.listen_port,
      TRAEFIK_PROVIDERS_FILE_DIRECTORY: '/data',
      TRAEFIK_PROVIDERS_FILE_WATCH: 'false',
      TRAEFIK_LOG: 'true',
      TRAEFIK_LOG_LEVEL: context.log_level,
      TRAEFIK_ACCESSLOG: context.access_log,
    },
  },
  cm_conf = {
    apiVersion: enums.apiVersion,
    kind: enums.ConfigMap,
    metadata: {
      name: context.name + '-conf',
    },
    data: {
      'app.yaml': |||
        http:
          services:
            relay-service:
              loadBalancer:
                {{ if env "REMOTE_SNI" }}
                serversTransport: relay-transport
                {{ end }}
                passHostHeader: false
                servers:
                - url: {{ env "REMOTE_ADDRESS" }}
          {{ if env "REMOTE_SNI" }}
          serversTransports:
            relay-transport:
              serverName: {{ env "REMOTE_SNI" }}
          {{ end}}
          routers:
            relay-router:
              rule: "PathPrefix(`/`)"
              service: relay-service
              tls: {}
        tls:
            certificates:
            - certFile: /cert/cert.pem
              keyFile: /cert/key.pem
      |||
    },
  },
  sec_cert = {
    apiVersion: enums.apiVersion,
    kind: enums.Secret,
    metadata:
      { name: context.name + '-cert' },
    type: 'Opaque',
    stringData:
      {
        'cert.pem': context.cert,
        'key.pem': context.key,
      },
  },
  deploy = {
    apiVersion: "apps/"+enums.apiVersion,
    kind: enums.Deployment,
    metadata:
      { name: context.name + '-deploy' },
    spec: {
      replicas: 1,
      selector: {
        matchLabels:
          { app: context.name },
      },
      strategy: { rollingUpdate: { maxSurge: '25%', maxUnavailable: '25%' }, type: 'RollingUpdate' },
      template: {
        metadata: {
          labels:
            { app: context.name },
        },
        spec: {
          containers: [{
            name: 'traefik',
            image: 'traefik:latest',
            imagePullPolicy: 'IfNotPresent',
            envFrom: [
              {
                configMapRef:
                  { name: context.name + '-env' },
              },
            ],
            ports: [
              { containerPort: 445 },
            ],
            resources: {
              limits: {
                cpu: '100m',
                'ephemeral-storage': '100M',
                memory: '200M',
              },
              requests: self.limits,
            },
            volumeMounts: [
              {
                mountPath: '/cert',
                name: 'cert',
              },
              {
                mountPath: '/data',
                name: 'data',
              },
            ],
          }],
          restartPolicy: 'Always',
          volumes: [
            {
              name: 'data',
              configMap: { name: context.name + '-conf' },
            },
            {
              name: 'cert',
              secret: {
                defaultMode: 420,
                secretName: context.name + '-cert',
              },
            },
          ],
        },
      },
    },
  },
  lb = {
    apiVersion: enums.apiVersion,
    kind: enums.Service,
    metadata:
      { name: context.name + '-loadbalancer' },
    spec:
      {
        ports:
          [{
            name: 'tcp-445',
            port: context.listen_port,
            protocol: 'TCP',
            targetPort: self.port,
          }],
        selector:
          { app: context.name },
        type: 'LoadBalancer',
      },
  };

std.manifestYamlStream([cm_env, cm_conf, sec_cert, deploy,lb])
