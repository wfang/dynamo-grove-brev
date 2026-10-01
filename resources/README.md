# Dynamo Lab Resources

This directory contains cached Helm charts and dashboard configurations for offline use.

## Helm Charts (Cached for Offline Use)

**Current Version:** v0.9.1

To update cached charts:

```bash
cd resources/

# Download v0.9.1 charts
helm fetch https://helm.ngc.nvidia.com/nvidia/ai-dynamo/charts/dynamo-crds-0.9.1.tgz
helm fetch https://helm.ngc.nvidia.com/nvidia/ai-dynamo/charts/dynamo-platform-0.9.1.tgz

# Verify downloads
ls -lh *.tgz
```

**Note:** The labs use `helm fetch` to download charts directly from NGC. These cached versions are for:
- Offline environments
- Faster lab setup (pre-downloaded)
- Version pinning for reproducibility

## Dashboard Configurations

- `dynamo-inference-dashboard.json` - Grafana dashboard for Dynamo metrics (used in Lab 2)

## Version History
- **v0.9.1** (Mar 2026): 
- **v0.8.0** (Jan 2026): K8s-native discovery, validation webhooks, enhanced observability
- **v0.7.1** (Previous): NATS/etcd required for distributed serving

## Updating for New Releases

When a new Dynamo version is released:

1. Download new chart versions (see commands above)
2. Update labs to reference new version in `RELEASE_VERSION` variable
3. Test all labs with new charts
4. Archive old versions (optional): `mkdir archive/ && mv *-0.7.1.tgz archive/`
5. Update this README with version notes
