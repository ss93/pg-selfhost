# pg-selfhost

Tired of Neon CU-hours and paying over the top for your simple hobby project?

Self-host PostgreSQL in 10 minutes for ~$4/month!!!

Browse your data with Drizzle Studio. 

Automated daily backups to Cloudflare R2.

One script to set up everything: PostgreSQL, SSL, firewall, user/database creation.

<!-- screenshot: drizzle studio showing a table -->

<img width="1910" height="928" alt="Screenshot 2026-02-18 at 8 33 34 PM" src="https://github.com/user-attachments/assets/17562a59-5d0e-4bc5-a1ce-a564fa2090d5" />

---

## What You Get

- A PostgreSQL database running on your own server
- SSL-encrypted connections out of the box
- Firewall configured to only allow your IP
- Drizzle Studio to browse/edit your data from your laptop
- Daily compressed backups uploaded to Cloudflare R2

---

## Step 1: Create a Hetzner Server

1. Sign up at [hetzner.com/cloud](https://www.hetzner.com/cloud/)
2. Click **Add Server**
3. Pick these settings:

| Setting | Value |
|---------|-------|
| Location | Wherever is closest to you |
| Image | **Ubuntu 24.04** |
| Type | **CX22** (2 vCPU, 4 GB RAM) — plenty for most projects |
| Networking | Leave defaults (public IPv4 + IPv6) |
| SSH Key | Add your public key (see below if you don't have one) |

4. Click **Create & Buy Now**
5. Copy the **IP address** of your new server

<img width="1842" height="773" alt="Screenshot 2026-02-18 at 8 31 14 PM" src="https://github.com/user-attachments/assets/5f6f2fd3-78da-4333-baaf-d766ac847f4a" />


### Firewall

Setup the firewall on your instance for TCP port 5432

<img width="1512" height="648" alt="Screenshot 2026-02-18 at 8 30 56 PM" src="https://github.com/user-attachments/assets/839b5a2a-3c62-440b-906e-b59b7c5c1e70" />

### Don't have an SSH key?

Run this on your laptop:

```bash
ssh-keygen -t ed25519
cat ~/.ssh/id_ed25519.pub
```

Copy the output and paste it into the Hetzner SSH key field.

---

## Step 2: Set Up PostgreSQL

SSH into your server:

```bash
ssh root@YOUR_SERVER_IP
```

Download and run the setup script:

```bash
curl -sO https://raw.githubusercontent.com/ss93/pg-selfhost/main/scripts/setup.sh
bash setup.sh
```

It will ask you for:

- **DB username** — pick anything (e.g. `myapp`)
- **DB name** — defaults to `<username>db`
- **Password** — use something strong
- **Allowed IPs** — your laptop's IP (find it at [whatismyip.com](https://whatismyip.com)), or type `all` to allow connections from any IP

> **Tip:** Use specific IPs if you know where you'll connect from. Use `all` if your IP changes often or multiple people/services need access — just make sure your password is strong.

When it's done, you'll see your connection string:

```
postgresql://myapp:yourpassword@YOUR_SERVER_IP:5432/myappdb?sslmode=require
```

Save this — you'll need it for your app and for Drizzle Studio.

<!-- screenshot: terminal showing setup complete output -->

---

## Step 3: Browse Your Data with Drizzle Studio

Back on your laptop, clone this repo:

```bash
git clone https://github.com/ss93/pg-selfhost.git
cd pg-selfhost
npm install
```

Create a `.env` file with your connection string:

```bash
echo 'DATABASE_URL=postgresql://myapp:yourpassword@YOUR_SERVER_IP:5432/myappdb?sslmode=require' > .env
```

Start Drizzle Studio:

```bash
npm run studio
```

Open [https://local.drizzle.studio](https://local.drizzle.studio) in your browser. You can now browse tables, run queries, and edit data.

<!-- screenshot: drizzle studio open in browser -->

---

## Step 4: Set Up Automated Backups (Cloudflare R2)

Backups are compressed with gzip and uploaded daily to Cloudflare R2. Old backups are automatically cleaned up.

### Create an R2 Bucket

1. Go to your [Cloudflare dashboard](https://dash.cloudflare.com) → **R2 Object Storage**
2. Click **Create bucket** and name it (e.g. `db-backups`)
3. Go to **R2** → **Overview** → **Manage R2 API Tokens**
4. Click **Create API token** with **Object Read & Write** permissions
5. Note these values:
   - **Access Key ID**
   - **Secret Access Key**
   - **Endpoint URL** — looks like `https://<ACCOUNT_ID>.r2.cloudflarestorage.com`

<!-- screenshot: cloudflare R2 bucket creation -->

<img width="1855" height="860" alt="Screenshot 2026-02-18 at 8 31 56 PM" src="https://github.com/user-attachments/assets/002a6e1d-f8e6-42c0-bdc9-01d67e93b33e" />

<img width="1919" height="838" alt="Screenshot 2026-02-18 at 8 41 49 PM" src="https://github.com/user-attachments/assets/b65336be-78bd-41e3-9f53-023407ad159a" />

<img width="1509" height="836" alt="Screenshot 2026-02-18 at 8 42 42 PM" src="https://github.com/user-attachments/assets/fa4f1db7-fba2-4ca8-9b09-cba82afa72eb" />

<img width="1494" height="840" alt="Screenshot 2026-02-18 at 8 43 10 PM" src="https://github.com/user-attachments/assets/35e381a8-fca3-4307-8f1a-bef287eed9d8" />


### Install Backups on Your Server

SSH into your server and run:

```bash
curl -sO https://raw.githubusercontent.com/ss93/pg-selfhost/main/scripts/setup-backups.sh
curl -sO https://raw.githubusercontent.com/ss93/pg-selfhost/main/scripts/backup.sh
bash setup-backups.sh
```

It will ask you for:

| Prompt | What to enter |
|--------|---------------|
| DB name | Same as during setup (e.g. `myappdb`) |
| DB user | Same as during setup (e.g. `myapp`) |
| Backup directory | Press Enter for default (`/var/backups/selfsql`) |
| Keep days | How many days to retain backups (default: `7`) |
| Backup hour | When to run daily (default: `3` = 3:00 AM) |
| Upload to S3? | `y` |
| S3 bucket | `s3://db-backups` |
| S3 endpoint | Your R2 endpoint URL |
| Access key ID | Your R2 access key |
| Secret access key | Your R2 secret key |

It will offer to run a test backup. Say yes to make sure everything works.

<!-- screenshot: terminal showing backup setup complete -->

---

## Restoring from a Backup

### From a local backup

```bash
gunzip -c /var/backups/selfsql/myappdb_20250101_030000.sql.gz | psql -U myapp myappdb
```

### From Cloudflare R2

```bash
# Download the backup
aws s3 cp s3://db-backups/myappdb_20250101_030000.sql.gz /tmp/restore.sql.gz \
  --endpoint-url https://YOUR_ACCOUNT_ID.r2.cloudflarestorage.com

# Restore it
gunzip -c /tmp/restore.sql.gz | psql -U myapp myappdb
```

---

## Connecting from Your App

Use the connection string from Step 2 in your application:

```
postgresql://myapp:yourpassword@YOUR_SERVER_IP:5432/myappdb?sslmode=require
```

Works with any PostgreSQL client — Node.js, Python, Go, Rails, etc.

**Node.js example (with Drizzle ORM):**

```ts
import { drizzle } from "drizzle-orm/node-postgres";

const db = drizzle(process.env.DATABASE_URL!);
```

---

## Allowing Additional IPs

If you get a new IP or want to allow a teammate to connect, re-run the setup script. It's safe to run multiple times — it won't duplicate anything.

```bash
ssh root@YOUR_SERVER_IP
bash setup.sh
```

Enter the same DB credentials and add the new IP(s), or type `all` to open it up.

---

## Cost Breakdown

| Service | Cost |
|---------|------|
| Hetzner CX22 | ~$4.35/month |
| Cloudflare R2 (10 GB free) | $0/month for most projects |
| **Total** | **~$4.35/month** |

Compare this to managed PostgreSQL services that start at $15–50/month.

---

## Troubleshooting

**Can't connect from my laptop?**
- Make sure your IP is in the allowed list. Check your IP at [whatismyip.com](https://whatismyip.com).
- Re-run `bash setup.sh` on the server to update allowed IPs.

**Drizzle Studio won't start?**
- Make sure you ran `npm install` first.
- Check that your `.env` file has the correct `DATABASE_URL`.

**Backups aren't uploading to R2?**
- SSH into the server and run `bash /opt/selfsql/backup.sh` manually to see errors.
- Check that the aws CLI is installed: `aws --version`
- Verify your R2 credentials in `/etc/selfsql/.env`.

**PostgreSQL won't start after setup?**
- Check logs: `journalctl -xeu postgresql`
- Verify config: `sudo -u postgres psql -c "SHOW config_file;"`

---

## License

MIT
