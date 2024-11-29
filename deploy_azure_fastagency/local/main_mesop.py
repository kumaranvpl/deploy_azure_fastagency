from fastagency import FastAgency
from fastagency.ui.mesop import MesopUI

from ..workflow import wf

app = FastAgency(
    provider=wf,
    ui=MesopUI(),
    title="Deploy Azure FastAgency",
)

# start the fastagency app with the following command
# gunicorn deploy_azure_fastagency.local.main_mesop:app
