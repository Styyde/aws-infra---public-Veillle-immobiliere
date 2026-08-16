# Identité du repo GitHub qui build/push l'image (flask-app) -- utilisé par
# la trust policy OIDC du rôle IAM github_actions (main.tf).
github_organization = "Styyde"
github_repository   = "flask-app---public-veille-immobiliere"

# Repo GitOps que Argo CD surveille et que la CI met à jour (bump du tag image).
gitops_repo_url = "https://github.com/Styyde/flask-gitops---public-veille-immobiliere.git"

# db_username reste à fournir séparément (variable sensible, pas de défaut) :
# via TF_VAR_db_username, un fichier *.auto.tfvars.gitignored, ou -var à l'apply.
