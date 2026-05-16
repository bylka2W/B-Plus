using System;

namespace BPlusGenerated
{
    public class Red : State
    {
        public override void Enter()
        {
            stop_traffic();
        }
        public override State OnTimer()
        {
            return new Green();
        }
    }

    public class Green : State
    {
        public override void Enter()
        {
            allow_traffic();
        }
        public override State OnTimer()
        {
            return new Yellow();
        }
    }

    public class Yellow : State
    {
        public override void Enter()
        {
            warn_traffic();
        }
        public override State OnTimer()
        {
            return new Red();
        }
    }

}
